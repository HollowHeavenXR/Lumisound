#!/bin/sh
# Recreate the two test bridges (py = legacy Python, rs = Rust in front of it).
docker rm -f lumi_py_test lumi_rs_test >/dev/null 2>&1
ENVF=$HOME/Projects/Lumisound/ios-bridge/.env
VOLS="-v lumi-test-music:/usermusic -v /mnt/fastssd/lumisound-server-library:/serverlibrary:ro"
docker run -d --name lumi_py_test --network lumi-test --env-file $ENVF -e DB_HOST=lumi_test_pg -e PORT=8002 -e USER_MUSIC_DIR=/usermusic -e SERVER_MUSIC_DIR=/serverlibrary -e PENDING_DOWNLOADS_DIR=/tmp/pending -e LUMISOUND_WHISPER_ENABLED=0 -e BUG_REPORT_WEBHOOK_URL= -e LIVE_PUSH_URL=http://lumi_rs_test:8002/internal/live-push $VOLS web-stack-ios-bridge-legacy uvicorn main:app --host 0.0.0.0 --port 8002 >/dev/null
docker run -d --name lumi_rs_test --network lumi-test --env-file $ENVF -e DB_HOST=lumi_test_pg -e PORT=8002 -e LEGACY_URL=http://lumi_py_test:8002 -e USER_MUSIC_DIR=/usermusic -e SERVER_MUSIC_DIR=/serverlibrary -e PENDING_DOWNLOADS_DIR=/tmp/pending -e YTDLP_POT_PROVIDER_URL= -e BUG_REPORT_WEBHOOK_URL= $VOLS web-stack-ios-bridge >/dev/null
docker network connect lumi-test-out lumi_py_test; docker network connect lumi-test-out lumi_rs_test
for i in $(seq 60); do docker exec lumi_rs_test curl -sf localhost:8002/health >/dev/null 2>&1 && docker exec lumi_rs_test curl -sf http://lumi_py_test:8002/health >/dev/null 2>&1 && break; sleep 1; done
echo "test bridges up"
