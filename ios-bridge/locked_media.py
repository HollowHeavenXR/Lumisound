"""Reading inside Lumisound-locked (`.lms`) cloud tracks.

A locked file is the iOS app's own container: an 8-byte `LMSLOCK1` magic header
followed by the real audio XOR-masked with a fixed 24-byte key. To anything that
expects audio — ffmpeg, ffprobe, mutagen, AVFoundation — those bytes are noise.
That single fact is behind a whole family of "the server can't see it" problems:

  * artwork could only come from a thumbnail the phone uploaded separately,
    because the server could not read the cover embedded in the file;
  * `bpm` was only ever filled in by on-device analysis on the iPhone, so a
    library filled from tvOS or from cloud backup had it for almost nothing —
    which is what left Smart Playlists with nothing to build from.

This module gives the server the same read access the clients have.

**It never modifies a stored file.** The obvious reading of "unlock it, extract,
then lock it again" is to unmask the file in place and re-mask it afterwards,
and that is a genuinely dangerous way to do it: a crash, a restart or a full disk
between the two halves leaves the user's only copy in a state that matches
neither what the server expects nor what the client expects. Instead the masked
bytes are streamed into a temporary file, read from there, and the temporary file
is deleted — the original is opened read-only and is never rewritten, so there is
no window in which it can be left wrong. The net effect is the same and the
failure mode is "we learn nothing this time" instead of "the track is corrupt".
"""
from __future__ import annotations

import asyncio
import contextlib
import logging
import math
import os
import pathlib
import struct
import subprocess
import tempfile
import urllib.request

logger = logging.getLogger("ios-bridge")

# Must stay byte-identical to LumisoundLockFormat (iOS) and TVLockFormat (tvOS).
LOCK_MAGIC = b"LMSLOCK1"
LOCK_KEY = bytes([
    0x4C, 0x75, 0x6D, 0x69, 0x53, 0x6F, 0x75, 0x6E,
    0x64, 0x45, 0x78, 0x63, 0x6C, 0x75, 0x73, 0x69,
    0x76, 0x65, 0x4C, 0x6F, 0x63, 0x6B, 0x21, 0x21,
])

_CHUNK = 1024 * 1024


def is_locked(path: pathlib.Path) -> bool:
    """True when the file carries the lock header.

    A `.lms` extension is NOT sufficient: older versions of the iOS app produced
    plain-renamed `.lms` files with no header at all, and those are already
    readable. Both clients handle that case, so the server has to as well.
    """
    try:
        with open(path, "rb") as f:
            return f.read(len(LOCK_MAGIC)) == LOCK_MAGIC
    except OSError:
        return False


def _unmask_into(src: pathlib.Path, dst_fd: int) -> None:
    """Streams `src` through the XOR into an already-open descriptor.

    Chunked rather than `read()` + `bytes(...)`: these are whole music files, and
    a 40MB FLAC read into memory and XORed into a second 40MB buffer is 80MB per
    track — fine once, ruinous when a backfill walks five hundred of them inside
    a container with a memory limit.
    """
    key = LOCK_KEY
    keylen = len(key)
    offset = 0
    with open(src, "rb") as f:
        header = f.read(len(LOCK_MAGIC))
        if header != LOCK_MAGIC:
            # Legacy plain-renamed .lms — copy through untouched.
            os.write(dst_fd, header)
            while chunk := f.read(_CHUNK):
                os.write(dst_fd, chunk)
            return
        while chunk := f.read(_CHUNK):
            # Key phase must continue across chunk boundaries, so the repeating
            # key is rotated to wherever the previous chunk left it.
            phase = offset % keylen
            rotated = key[phase:] + key[:phase]
            pad = rotated * (len(chunk) // keylen + 2)
            os.write(dst_fd, bytes(b ^ k for b, k in zip(chunk, pad)))
            offset += len(chunk)


@contextlib.contextmanager
def readable_copy(path: pathlib.Path, suffix: str = ""):
    """Yields a path to a temporarily readable copy, deleted on exit.

    Unlocked files are yielded as-is with no copy at all — there is nothing to
    undo, and copying a file only to read it is wasted I/O on a disk that is
    already the slow part of every backfill.
    """
    if not is_locked(path):
        yield path
        return

    fd, tmp = tempfile.mkstemp(suffix=suffix or path.suffix, prefix="lms-")
    try:
        _unmask_into(path, fd)
        os.close(fd)
        fd = -1
        yield pathlib.Path(tmp)
    finally:
        if fd >= 0:
            with contextlib.suppress(OSError):
                os.close(fd)
        with contextlib.suppress(OSError):
            os.unlink(tmp)


def inner_suffix(path: pathlib.Path) -> str:
    """The real container extension inside a lock, e.g. "Song.opus.lms" -> ".opus".

    ffmpeg and mutagen both use the extension as a demuxer hint, so handing them
    a temp file called `*.lms` makes them guess — and guess wrong for Ogg.
    """
    if path.suffix.lower() == ".lms":
        inner = pathlib.Path(path.stem).suffix
        if inner:
            return inner
    return path.suffix


# ---------------------------------------------------------------------------
# Artwork
# ---------------------------------------------------------------------------

_MIN_IMAGE_BYTES = 2048


def _ffmpeg_cover(audio: pathlib.Path) -> bytes | None:
    """Embedded cover art, via ffmpeg's attached-picture stream."""
    for mapping in ("0:v:0", "0:V:0"):
        out = tempfile.NamedTemporaryFile(suffix=".jpg", delete=False)
        out.close()
        try:
            proc = subprocess.run(
                ["ffmpeg", "-v", "quiet", "-y", "-i", str(audio),
                 "-map", mapping, "-c:v", "mjpeg", "-frames:v", "1",
                 "-f", "image2", out.name],
                capture_output=True, timeout=60,
            )
            data = pathlib.Path(out.name).read_bytes() if proc.returncode == 0 else b""
            if len(data) > _MIN_IMAGE_BYTES:
                return data
        except (subprocess.SubprocessError, OSError):
            pass
        finally:
            with contextlib.suppress(OSError):
                os.unlink(out.name)
    return None


def _tag_artwork(audio: pathlib.Path) -> bytes | None:
    """Artwork reachable only through the tags, not through ffmpeg.

    Two sources ffmpeg will not give you:

      * FLAC/Ogg picture blocks that ffmpeg exposes inconsistently;
      * `lumisound_thumbnail`, a Vorbis comment the iOS app writes holding the
        artwork's URL. ffprobe does not print Ogg comments at all, which is
        precisely why this went unnoticed for so long — every tool the server
        used reported the file as having no artwork when it plainly listed one.
    """
    try:
        from mutagen import File as MutagenFile
    except ImportError:
        return None
    try:
        f = MutagenFile(str(audio))
    except Exception:
        return None
    if f is None:
        return None

    pics = getattr(f, "pictures", None)
    if pics:
        data = pics[0].data
        if len(data) > _MIN_IMAGE_BYTES:
            return data

    tags = f.tags or {}
    try:
        value = tags.get("lumisound_thumbnail")
    except Exception:
        value = None
    if isinstance(value, list):
        value = value[0] if value else None
    if not value:
        return None
    value = str(value).strip()

    if value.startswith("http"):
        data = _fetch(value)
        if data:
            return data
        # maxresdefault does not exist for every video; walk down the ladder so a
        # track gets the best art that actually exists rather than none.
        if "/vi/" in value:
            stem = value.rsplit("/", 1)[0]
            for size in ("maxresdefault", "sddefault", "hqdefault", "mqdefault", "default"):
                data = _fetch(f"{stem}/{size}.jpg")
                if data:
                    return data
        return None

    # Tolerate a data: URI or bare base64, in case an older client wrote bytes.
    import base64
    try:
        payload = value.split(",", 1)[1] if value.startswith("data:") else value
        data = base64.b64decode(payload, validate=False)
        if data[:2] == b"\xff\xd8" or data[:8] == b"\x89PNG\r\n\x1a\n":
            return data
    except Exception:
        pass
    return None


def _fetch(url: str) -> bytes | None:
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "Lumisound/artwork"})
        with urllib.request.urlopen(req, timeout=20) as r:
            if r.status != 200:
                return None
            data = r.read()
        # YouTube serves a small grey placeholder for sizes that do not exist.
        return data if len(data) > _MIN_IMAGE_BYTES else None
    except Exception:
        return None


def extract_artwork(path: pathlib.Path) -> tuple[bytes | None, str]:
    """Best available artwork for a track, locked or not.

    Returns `(data, source)` so callers can report WHICH route produced it —
    the difference between "this library has no embedded art" and "we only ever
    looked in one place" is otherwise invisible.
    """
    suffix = inner_suffix(path)
    try:
        with readable_copy(path, suffix=suffix) as readable:
            data = _ffmpeg_cover(readable)
            if data:
                return data, "embedded"
            data = _tag_artwork(readable)
            if data:
                return data, "tag"
    except Exception as exc:
        logger.warning("extract_artwork failed for %s: %s", path.name, exc)
        return None, "error"
    return None, "none"


# ---------------------------------------------------------------------------
# Tempo
# ---------------------------------------------------------------------------

_BPM_SAMPLE_RATE = 11025
_BPM_MAX_SECONDS = 120
_BPM_MIN = 60.0
_BPM_MAX = 200.0


def _decode_mono(audio: pathlib.Path, seconds: int) -> bytes | None:
    """Decodes the middle of a track to 16-bit mono PCM.

    The MIDDLE, not the start: intros are frequently unrepresentative — a long
    ambient pad or a spoken lead-in gives a tempo that has nothing to do with the
    body of the song.
    """
    try:
        probe = subprocess.run(
            ["ffprobe", "-v", "quiet", "-show_entries", "format=duration",
             "-of", "default=nw=1:nk=1", str(audio)],
            capture_output=True, text=True, timeout=30,
        )
        duration = float((probe.stdout or "0").strip() or 0)
    except Exception:
        duration = 0.0

    start = max(0.0, (duration - seconds) / 2) if duration > seconds else 0.0
    try:
        proc = subprocess.run(
            ["ffmpeg", "-v", "quiet", "-ss", str(start), "-i", str(audio),
             "-t", str(seconds), "-ac", "1", "-ar", str(_BPM_SAMPLE_RATE),
             "-f", "s16le", "-"],
            capture_output=True, timeout=180,
        )
    except subprocess.SubprocessError:
        return None
    return proc.stdout if proc.returncode == 0 and proc.stdout else None


def estimate_bpm(path: pathlib.Path) -> float | None:
    """Estimates tempo, or None when the track has no steady beat to find.

    Method: an onset-strength envelope (positive frame-to-frame change in
    short-window energy — a beat is a sudden RISE, so falls are discarded),
    autocorrelated over the plausible tempo range. The lag with the strongest
    correlation is the beat period.

    Deliberately conservative about what it will claim. Returning a wrong tempo
    is worse than returning nothing: a wrong value silently mis-sorts a track
    into the wrong Smart Playlist and beat-snaps a crossfade to a beat that is
    not there, and nothing downstream can tell it is wrong. So a weak or
    ambiguous peak yields None and the track is simply left without a BPM.
    """
    try:
        import numpy as np
    except ImportError:
        logger.warning("estimate_bpm: numpy unavailable")
        return None

    suffix = inner_suffix(path)
    try:
        with readable_copy(path, suffix=suffix) as readable:
            raw = _decode_mono(readable, _BPM_MAX_SECONDS)
    except Exception as exc:
        logger.warning("estimate_bpm failed for %s: %s", path.name, exc)
        return None
    if not raw or len(raw) < 4 * _BPM_SAMPLE_RATE * 2:  # need a few seconds
        return None

    samples = np.frombuffer(raw[: len(raw) // 2 * 2], dtype="<i2").astype(np.float32) / 32768.0
    if samples.size == 0:
        return None

    # ~11.6ms frames: short enough to resolve a beat, long enough to smooth
    # individual waveform cycles out of the envelope.
    hop = 128
    frames = samples.size // hop
    if frames < 64:
        return None
    energy = np.sqrt((samples[: frames * hop].reshape(frames, hop) ** 2).mean(axis=1))

    # Onset strength: rises only. Falls carry no beat information and, left in,
    # make the envelope correlate with itself at every lag.
    flux = np.diff(energy, prepend=energy[:1])
    flux[flux < 0] = 0
    if flux.max() <= 0:
        return None
    flux = flux - flux.mean()

    frame_rate = _BPM_SAMPLE_RATE / hop
    min_lag = int(frame_rate * 60.0 / _BPM_MAX)
    max_lag = int(frame_rate * 60.0 / _BPM_MIN)
    if max_lag >= flux.size:
        max_lag = flux.size - 1
    if min_lag < 1 or max_lag <= min_lag:
        return None

    corr = np.correlate(flux, flux, mode="full")[flux.size - 1:]
    window = corr[min_lag:max_lag + 1]
    if window.size == 0 or corr[0] <= 0:
        return None

    best = int(np.argmax(window))
    peak = window[best]
    # Normalised against zero-lag energy, so the threshold means the same thing
    # for a quiet track as for a loud one.
    strength = float(peak / corr[0])
    if strength < 0.10:
        return None

    lag = min_lag + best
    bpm = 60.0 * frame_rate / lag

    # Fold into a musically sensible range. Autocorrelation cannot tell a tempo
    # from half or double it — both are real peaks — so 170 for a 85bpm track is
    # a coin toss rather than an error. Preferring the 70-140 band is what a
    # listener would usually call the tempo.
    while bpm > 140 and bpm / 2 >= _BPM_MIN:
        bpm /= 2
    while bpm < 70 and bpm * 2 <= _BPM_MAX:
        bpm *= 2
    if not (_BPM_MIN <= bpm <= _BPM_MAX):
        return None
    return round(bpm, 1)


# ---------------------------------------------------------------------------
# Async wrappers — both of the above block on ffmpeg and on disk.
# ---------------------------------------------------------------------------

async def extract_artwork_async(path: pathlib.Path) -> tuple[bytes | None, str]:
    return await asyncio.to_thread(extract_artwork, path)


async def estimate_bpm_async(path: pathlib.Path) -> float | None:
    return await asyncio.to_thread(estimate_bpm, path)


# ---------------------------------------------------------------------------
# Transition profile — how a track ENDS and how the next one BEGINS.
# ---------------------------------------------------------------------------
#
# The crossfade length was being chosen from the outgoing track's tail LEVEL. A
# level alone cannot answer the question that actually matters, because the two
# endings that most need different treatment look identical by it:
#
#   * a track that stops dead at full volume, and
#   * a track holding a sustained final chord at full volume.
#
# Overlapping the first destroys a deliberate ending; overlapping the second is
# exactly right. What separates them is the SLOPE of the tail — whether the
# energy is falling away or holding — and whether there is an abrupt cut at the
# very end. Same on the other side: a track that fades in can be overlapped
# generously because there is nothing there to smear, while one that opens on a
# hard downbeat wants a short overlap so the hit lands clean.
#
# All of this is measured server-side, inside the lock, so iOS and tvOS share one
# implementation of the judgement rather than each carrying their own heuristic
# that drifts from the other.

_PROFILE_SR = 8000
_PROFILE_WINDOW = 0.05          # 50ms envelope frames
_OUTRO_SECONDS = 10.0
_INTRO_SECONDS = 6.0
# How far back from the detected end of the music the cold-stop check looks —
# see its own comment below for why this cannot be a handful of frames.
_COLD_STOP_TAIL_SECONDS = 1.0


def _envelope(pcm: bytes, window_s: float = _PROFILE_WINDOW):
    import numpy as np
    samples = np.frombuffer(pcm[: len(pcm) // 2 * 2], dtype="<i2").astype(np.float32) / 32768.0
    if samples.size == 0:
        return None
    w = max(1, int(_PROFILE_SR * window_s))
    frames = samples.size // w
    if frames < 3:
        return None
    return np.sqrt((samples[: frames * w].reshape(frames, w) ** 2).mean(axis=1))


def _decode_range(audio: pathlib.Path, start: float, length: float) -> bytes | None:
    try:
        proc = subprocess.run(
            ["ffmpeg", "-v", "quiet", "-ss", str(max(0.0, start)), "-i", str(audio),
             "-t", str(length), "-ac", "1", "-ar", str(_PROFILE_SR), "-f", "s16le", "-"],
            capture_output=True, timeout=120,
        )
    except subprocess.SubprocessError:
        return None
    return proc.stdout if proc.returncode == 0 and proc.stdout else None


def _duration_of(audio: pathlib.Path) -> float:
    try:
        probe = subprocess.run(
            ["ffprobe", "-v", "quiet", "-show_entries", "format=duration",
             "-of", "default=nw=1:nk=1", str(audio)],
            capture_output=True, text=True, timeout=30,
        )
        return float((probe.stdout or "0").strip() or 0)
    except Exception:
        return 0.0


def transition_profile(path: pathlib.Path) -> dict | None:
    """How this track ends and begins, for choosing a crossfade.

    The first thing it establishes is how much DEAD AIR is on the end, because
    that turned out to be the thing most wrong with the existing crossfade.

    A fade triggered at `duration - 6s` assumes the track is still playing music
    six seconds from the end. Measured across a real library, 8 tracks in 25 have
    more than 1.5s of trailing silence and one had fifteen. Those transitions
    were not blending two tracks at all — they were fading the next one up over a
    tail that had already finished, which is both the wrong sound and the reason
    a crossfade can feel like an awkward gap rather than a join.

    Everything else here is therefore measured against the last of the real
    music, not the last of the file.

    Figures are in dB because that is the domain these decisions are made in — a
    linear RMS ratio compresses exactly the quiet end of the range where the
    difference between "fading out" and "stopped dead" lives.
    """
    try:
        import numpy as np
    except ImportError:
        return None

    suffix = inner_suffix(path)
    try:
        with readable_copy(path, suffix=suffix) as readable:
            duration = _duration_of(readable)
            if duration < 8:
                return None
            # Look back far enough to find the end of the music even when the
            # dead air is long.
            look = min(45.0, duration)
            tail_pcm = _decode_range(readable, duration - look, look)
            head_pcm = _decode_range(readable, 0.0, _INTRO_SECONDS)
    except Exception as exc:
        logger.warning("transition_profile failed for %s: %s", path.name, exc)
        return None

    tail = _envelope(tail_pcm) if tail_pcm else None
    head = _envelope(head_pcm) if head_pcm else None
    if tail is None or head is None:
        return None

    floor = 1e-5

    def db(x):
        return float(20.0 * math.log10(max(float(x), floor)))

    # --- Trailing silence --------------------------------------------------
    # Same threshold rule as the leading-silence trimmer: relative to the
    # track's own peak, with an absolute floor so a quiet outro is not mistaken
    # for silence.
    tail_peak = float(tail.max())
    if tail_peak <= 0:
        return None
    threshold = max(tail_peak * 0.01, 0.0015)
    above = np.nonzero(tail > threshold)[0]
    if above.size == 0:
        return None
    last_music = int(above[-1])
    trailing_silence = float((tail.size - 1 - last_music) * _PROFILE_WINDOW)

    # --- Outro, measured on the MUSIC -------------------------------------
    music = tail[: last_music + 1]
    window_frames = int(_OUTRO_SECONDS / _PROFILE_WINDOW)
    outro = music[-window_frames:] if music.size > window_frames else music
    frames = outro.size
    if frames < 4:
        return None

    t = (np.arange(frames) * _PROFILE_WINDOW).astype(np.float64)
    outro_db = np.array([db(v) for v in outro])
    slope_db_per_s = float(np.polyfit(t, outro_db, 1)[0])

    # A cold stop is the music's final moment collapsing relative to the body of
    # the outro WITHOUT having been fading toward it. Judged against the median
    # rather than the peak, so one loud hit near the end does not make an
    # ordinary ending look like a cliff.
    #
    # BUGFIX (reported in the field as "tracks randomly skip or fade into the
    # next track" — SmartCrossfade was shrinking the overlap to barely more
    # than its 1.5s floor for the large majority of a real library, confirmed
    # via iOS client telemetry: "Crossfade trigger reached" logged a 1.2-2.0s
    # lead on 8 of 10 consecutive transitions across completely unrelated
    # tracks, independent of track length). `last` used to be the final THREE
    # FRAMES (150ms) of `music` — which, by construction, sits immediately
    # adjacent to the exact threshold crossing `last_music` is defined by.
    # That is not a measurement of whether the track stopped abruptly; it is
    # almost guaranteed to read as a "collapse" for ANY ordinary ending,
    # because a sustained note/chord's natural release/reverb tail decaying
    # toward that same silence threshold is exactly what the final 150ms of
    # almost every real recording looks like, whether or not the track
    # actually "stops cold." A genuinely instantaneous edit (full volume with
    # zero decay, cut dead) would in fact show NO drop here at all, since
    # `music` only extends through the last above-threshold sample — this was
    # measuring the wrong thing entirely, flagging the near-universal case of
    # "has a brief natural tail" as `outro_cold_stop`, not the rare case of
    # "has none." Widened to a full second so the comparison reflects whether
    # the music was still near its outro body level in the second leading
    # into the stop, not just the single instant furthest into the decay.
    tail_frames = max(3, min(frames - 1, int(_COLD_STOP_TAIL_SECONDS / _PROFILE_WINDOW)))
    last = float(np.median(outro[-tail_frames:]))
    body = float(np.median(outro[: max(1, frames - tail_frames)]))
    drop_db = db(body) - db(last)
    cold_stop = bool(drop_db > 12.0 and slope_db_per_s > -2.0)

    # --- Intro -------------------------------------------------------------
    head_peak = float(head.max())
    head_db = np.array([db(v) for v in head])
    lead_threshold = db(head_peak) - 12.0
    head_above = np.nonzero(head_db >= lead_threshold)[0]
    lead_in = float(head_above[0] * _PROFILE_WINDOW) if head_above.size else 0.0
    # Hardness = how fast it reaches full level ONCE IT HAS STARTED.
    #
    # The first attempt used the largest single-frame rise anywhere in the
    # opening, which measured almost exactly 1.0 for every track: the
    # silence-to-signal step at the very beginning is a huge jump in dB for a
    # fade-in and a downbeat alike, so it separated nothing. It was also
    # redundant, since `lead_in` already says whether a track starts from
    # silence. Time-to-full-level is the thing that actually differs — a
    # downbeat is there immediately, a fade-in climbs for seconds.
    onset_frame = int(head_above[0]) if head_above.size else 0
    target = db(head_peak) - 3.0
    reached = np.nonzero(head_db[onset_frame:] >= target)[0]
    if reached.size:
        rise_seconds = float(reached[0] * _PROFILE_WINDOW)
        # 0s -> 1.0 (instant), 2s or more -> 0.0 (gradual).
        onset_hardness = float(np.clip(1.0 - rise_seconds / 2.0, 0.0, 1.0))
    else:
        onset_hardness = 0.0

    return {
        "trailing_silence_s": round(trailing_silence, 2),
        "outro_slope_db_per_s": round(slope_db_per_s, 2),
        "outro_cold_stop": cold_stop,
        "outro_tail_db": round(db(last), 1),
        "intro_lead_in_s": round(lead_in, 2),
        "intro_onset_hardness": round(onset_hardness, 3),
    }


async def transition_profile_async(path: pathlib.Path) -> dict | None:
    return await asyncio.to_thread(transition_profile, path)


# ---------------------------------------------------------------------------
# Spectral profile — what a track's tonal balance actually IS.
# ---------------------------------------------------------------------------
#
# Auto EQ picked a preset from the genre TAG, falling back to a tempo band. Both
# are metadata, and neither describes how a track sounds. A genre string is
# frequently absent or wrong on a downloaded track, and two songs sharing one are
# routinely mastered nothing alike; tempo says even less — it is a rate, not a
# tonal balance. So the chosen curve had no relationship to whether a track was
# already bass-heavy (where a bass boost makes it muddy) or genuinely thin.
#
# This measures the thing the decision needs: average energy in the same ten
# bands the equaliser has, expressed in dB RELATIVE to the track's own broadband
# level. Relative rather than absolute so the figure describes tonal balance
# rather than how loud the track was mastered — two masters of the same song at
# different levels should read as the same shape, because for EQ purposes they
# are.

# Matches EQPreset.bands on iOS exactly.
EQ_BANDS_HZ = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
_SPECTRAL_SR = 32000          # Nyquist 16kHz — enough for the top band
_SPECTRAL_SECONDS = 60
_SPECTRAL_FFT = 4096


def spectral_profile(path: pathlib.Path) -> list[float] | None:
    """Per-band level in dB relative to the track's overall level, or None.

    Ten values, in `EQ_BANDS_HZ` order. Positive means that band sits above the
    track's own average; negative means below.
    """
    try:
        import numpy as np
    except ImportError:
        return None

    suffix = inner_suffix(path)
    try:
        with readable_copy(path, suffix=suffix) as readable:
            # The middle again, for the same reason tempo uses it: an intro is
            # frequently unrepresentative of the body of the track.
            duration = _duration_of(readable)
            start = max(0.0, (duration - _SPECTRAL_SECONDS) / 2) if duration > _SPECTRAL_SECONDS else 0.0
            proc = subprocess.run(
                ["ffmpeg", "-v", "quiet", "-ss", str(start), "-i", str(readable),
                 "-t", str(_SPECTRAL_SECONDS), "-ac", "1", "-ar", str(_SPECTRAL_SR),
                 "-f", "s16le", "-"],
                capture_output=True, timeout=180,
            )
            raw = proc.stdout if proc.returncode == 0 else None
    except Exception as exc:
        logger.warning("spectral_profile failed for %s: %s", path.name, exc)
        return None
    if not raw or len(raw) < _SPECTRAL_FFT * 4:
        return None

    samples = np.frombuffer(raw[: len(raw) // 2 * 2], dtype="<i2").astype(np.float64) / 32768.0
    hop = _SPECTRAL_FFT // 2
    frames = (samples.size - _SPECTRAL_FFT) // hop
    if frames < 4:
        return None

    window = np.hanning(_SPECTRAL_FFT)
    freqs = np.fft.rfftfreq(_SPECTRAL_FFT, 1.0 / _SPECTRAL_SR)

    # Averaged over the whole excerpt rather than taken from one frame: a single
    # window catches whatever happened to be playing at that instant, which for
    # a track with a sparse arrangement is not its tonal balance at all.
    power = np.zeros(freqs.size)
    for i in range(frames):
        seg = samples[i * hop: i * hop + _SPECTRAL_FFT] * window
        spectrum = np.abs(np.fft.rfft(seg)) ** 2
        power += spectrum
    power /= frames

    total = float(power.sum())
    if total <= 0:
        return None

    out: list[float] = []
    for centre in EQ_BANDS_HZ:
        # One octave wide, which is roughly what a ten-band graphic EQ's filters
        # actually cover, so the measurement matches what the control can change.
        lo, hi = centre / math.sqrt(2), centre * math.sqrt(2)
        mask = (freqs >= lo) & (freqs < hi)
        if not mask.any():
            out.append(0.0)
            continue
        band = float(power[mask].sum())
        # Per-Hz density, so a wide top band is not credited simply for being
        # wide — otherwise every track would read as bright.
        width = float(freqs[mask].size)
        density = band / max(1.0, width)
        ref = total / max(1.0, float(freqs.size))
        out.append(round(10.0 * math.log10(max(density, 1e-12) / max(ref, 1e-12)), 2))
    return out


async def spectral_profile_async(path: pathlib.Path) -> list[float] | None:
    return await asyncio.to_thread(spectral_profile, path)
