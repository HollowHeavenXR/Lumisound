# Lumisound bridge — host deploy files

The bridge server itself is Rust: `../rust/bridge` (axum + sqlx), built from
`../rust/Dockerfile`. This folder only holds what the host needs to run it:

- `docker-compose.yml` — standalone compose for the bridge + bgutil PO-token
  provider (production runs the same service block from `~/Projects/web-stack`).
- `.env` — secrets (gitignored): `IOS_JWT_SECRET`, `IOS_BRIDGE_API_KEY`,
  `ADMIN_TOKEN`, `GEMINI_API_KEY`, `YOUTUBE_API_KEY`, `BUG_REPORT_WEBHOOK_URL`, …
- `cookies.txt` — YouTube cookie jar mounted read-only into the container.
- `refresh_youtube_cookies.sh` + `lumisound-youtube-cookies-refresh.*` — host
  systemd units that keep `cookies.txt` fresh.

## Run

```bash
docker compose up -d --build
curl -s localhost:8002/health   # {"status":"ok",...,"engine":"rust"}
```

The container carries only external CLIs the bridge spawns: yt-dlp (+ deno,
bgutil plugin, aria2c), ffmpeg/ffprobe, AtomicParsley, fpcalc, and Demucs for
stem separation. The admin dashboard is at `/admin`.
