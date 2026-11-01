//! LUMI_SPEED_FILES=a.opus,b.m4a cargo test --release -p lumisound-media --test opus_speed -- --nocapture
//! Full-rate stereo decode speed (what a playback deck needs), as a multiple of real time.
use symphonia::core::codecs::DecoderOptions;
use symphonia::core::formats::FormatOptions;
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::MetadataOptions;
use symphonia::core::probe::Hint;

#[test]
fn decode_speed() {
    let Ok(files) = std::env::var("LUMI_SPEED_FILES") else { return };
    for f in files.split(',') {
        let p = std::path::Path::new(f);
        let mss = MediaSourceStream::new(Box::new(std::fs::File::open(p).unwrap()), Default::default());
        let mut hint = Hint::new();
        if let Some(e) = p.extension().and_then(|e| e.to_str()) {
            hint.with_extension(e);
        }
        let mut fmt = symphonia::default::get_probe().format(&hint, mss, &FormatOptions::default(), &MetadataOptions::default()).unwrap().format;
        let track = fmt.default_track().unwrap().clone();
        let mut dec = lumisound_media::opus::codecs().make(&track.codec_params, &DecoderOptions::default()).unwrap();
        let rate = track.codec_params.sample_rate.unwrap_or(48_000) as f64;
        let t = std::time::Instant::now();
        let mut frames = 0u64;
        let mut packets = 0u64;
        while let Ok(pk) = fmt.next_packet() {
            if pk.track_id() != track.id {
                continue;
            }
            packets += 1;
            if let Ok(d) = dec.decode(&pk) {
                frames += d.frames() as u64;
            }
            if frames as f64 / rate > 60.0 {
                break;
            }
        }
        let secs = t.elapsed().as_secs_f64();
        let audio = frames as f64 / rate;
        println!("{}: {:.1}s audio in {:.2}s = {:.1}x real time ({} packets, codec {:?})", p.file_name().unwrap().to_string_lossy(), audio, secs, audio / secs, packets, track.codec_params.codec);
    }
}

/// LUMI_REF=<file.opus>:<ffmpeg f32le 48k stereo raw> — sample-accurate SNR vs libopus.
#[test]
fn matches_libopus() {
    let Ok(spec) = std::env::var("LUMI_REF") else { return };
    for pair in spec.split(',') {
        let (f, raw) = pair.split_once(':').unwrap();
        let reference: Vec<f32> = std::fs::read(raw).unwrap().chunks_exact(4).map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]])).collect();
        let p = std::path::Path::new(f);
        let mss = MediaSourceStream::new(Box::new(std::fs::File::open(p).unwrap()), Default::default());
        let mut hint = Hint::new();
        hint.with_extension("opus");
        let mut fmt = symphonia::default::get_probe().format(&hint, mss, &FormatOptions { enable_gapless: true, ..Default::default() }, &MetadataOptions::default()).unwrap().format;
        let track = fmt.default_track().unwrap().clone();
        let mut dec = lumisound_media::opus::codecs().make(&track.codec_params, &DecoderOptions::default()).unwrap();
        let mut ours: Vec<f32> = Vec::new();
        while ours.len() < reference.len() + 96_000 {
            let Ok(pk) = fmt.next_packet() else { break };
            if let Ok(d) = dec.decode(&pk) {
                let mut sb = symphonia::core::audio::SampleBuffer::<f32>::new(d.capacity() as u64, *d.spec());
                sb.copy_interleaved_ref(d);
                ours.extend_from_slice(sb.samples());
            }
        }
        // Align for decoder pre-skip differences (search ±1000 frames).
        let n = reference.len().min(ours.len() - 4000);
        let mut best = (0i64, f64::MAX);
        for off in -1000i64..=1000 {
            let mut err = 0.0;
            let mut cnt = 0;
            for i in (960_000..1_056_000).step_by(2) {
                let j = i as i64 + off * 2;
                if j < 0 || j as usize >= ours.len() { continue; }
                err += (ours[j as usize] as f64 - reference[i] as f64).powi(2);
                cnt += 1;
            }
            let e = err / cnt.max(1) as f64;
            if e < best.1 { best = (off, e); }
        }
        let off = best.0;
        let (mut sig, mut noise) = (0.0, 0.0);
        for i in 0..n {
            let j = i as i64 + off * 2;
            if j < 0 || j as usize >= ours.len() { continue; }
            sig += (reference[i] as f64).powi(2);
            noise += (ours[j as usize] as f64 - reference[i] as f64).powi(2);
        }
        let snr = 10.0 * (sig / noise.max(1e-20)).log10();
        println!("{f}: offset {off} frames, SNR vs libopus {snr:.1} dB over {:.1}s", n as f64 / 96_000.0);
        assert!(snr > 40.0, "{f} SNR {snr:.1} dB");
    }
}
