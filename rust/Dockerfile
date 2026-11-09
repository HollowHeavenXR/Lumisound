# Lumisound bridge (Rust). The runtime image carries only the external CLIs the
# server drives as child processes: yt-dlp (+ deno for YouTube's JS challenge,
# the bgutil PO-token plugin and aria2c), ffmpeg/ffprobe, AtomicParsley and
# fpcalc, plus Demucs (htdemucs) for stem separation and the whisper model
# Aria Lyrics runs (whisper.cpp itself is linked into the bridge binary). No Python application
# code runs in it; the bridge only spawns these tools.
FROM rust:1-bookworm AS build
# whisper.cpp (Aria Lyrics, linked through whisper-rs) needs CMake + Clang.
RUN apt-get update && apt-get install -y --no-install-recommends cmake clang libclang-dev && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY Cargo.toml Cargo.lock ./
COPY bridge bridge
COPY core core
COPY media media
COPY rpc rpc
COPY vendor vendor
RUN --mount=type=cache,target=/usr/local/cargo/registry --mount=type=cache,target=/src/target \
    CARGO_BUILD_JOBS=2 CMAKE_BUILD_PARALLEL_LEVEL=2 cargo build --release -p lumisound-bridge && cp target/release/lumisound-bridge /lumisound-bridge

FROM python:3.12-slim
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg curl unzip ca-certificates atomicparsley aria2 \
      libchromaprint-tools mesa-va-drivers libsndfile1 \
    && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL https://deno.land/install.sh | DENO_INSTALL=/usr/local sh && test -x /usr/local/bin/deno
# torch/torchaudio pinned: demucs 4.0.1 needs torchaudio's legacy save()
# backend, which 2.3.1 still carries (newer releases need torchcodec).
RUN pip install --no-cache-dir torch==2.3.1 torchaudio==2.3.1 --index-url https://download.pytorch.org/whl/cpu \
    && pip install --no-cache-dir numpy==2.3.3 soundfile demucs==4.0.1
ENV TORCH_HOME=/app/cache/demucs
RUN python -c "from demucs.pretrained import get_model; get_model('htdemucs'); print('htdemucs cached')"
# yt-dlp[default] brings mutagen (thumbnail/metadata embedding into
# Opus/M4A), pycryptodomex, brotli, websockets and certifi.
RUN pip install --no-cache-dir "yt-dlp[default]" yt-dlp-ejs bgutil-ytdlp-pot-provider
# Aria Lyrics speech model (whisper small, multilingual, q5_1 ~190 MB).
RUN mkdir -p /app/models && curl -fsSL -o /app/models/ggml-small-q5_1.bin \
      https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small-q5_1.bin \
    && test "$(stat -c %s /app/models/ggml-small-q5_1.bin)" -gt 150000000
WORKDIR /app
COPY --from=build /lumisound-bridge /usr/local/bin/lumisound-bridge
COPY bridge/schema.sql /app/schema.sql
ENV RUST_LOG=info
EXPOSE 8002
CMD ["lumisound-bridge"]
