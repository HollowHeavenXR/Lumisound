# Lumisound bridge (Rust). The runtime image carries only the external CLIs the
# server drives as child processes: yt-dlp (+ deno for YouTube's JS challenge,
# the bgutil PO-token plugin and aria2c), ffmpeg/ffprobe, AtomicParsley and
# fpcalc, plus Demucs (htdemucs) for stem separation. No Python application
# code runs in it; the bridge only spawns these tools.
FROM rust:1-bookworm AS build
WORKDIR /src
COPY Cargo.toml Cargo.lock ./
COPY bridge bridge
COPY core core
COPY media media
COPY rpc rpc
RUN --mount=type=cache,target=/usr/local/cargo/registry --mount=type=cache,target=/src/target \
    CARGO_BUILD_JOBS=3 cargo build --release -p lumisound-bridge && cp target/release/lumisound-bridge /lumisound-bridge

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
RUN pip install --no-cache-dir yt-dlp yt-dlp-ejs bgutil-ytdlp-pot-provider
WORKDIR /app
COPY --from=build /lumisound-bridge /usr/local/bin/lumisound-bridge
COPY bridge/schema.sql /app/schema.sql
ENV RUST_LOG=info
EXPOSE 8002
CMD ["lumisound-bridge"]
