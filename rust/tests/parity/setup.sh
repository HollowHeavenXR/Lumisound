#!/bin/sh
# Fresh isolated rig: tmpfs copy of the prod DB with outbound hooks/push
# blanked, both bridges, and tokens.json (user, b, op, api, admin).
set -e
H=$(cd "$(dirname "$0")" && pwd)
docker rm -f lumi_test_pg lumi_py_test lumi_rs_test >/dev/null 2>&1 || true
docker network create --internal lumi-test >/dev/null 2>&1 || true
docker network create lumi-test-out >/dev/null 2>&1 || true
docker run -d --name lumi_test_pg --network lumi-test -e POSTGRES_USER=botuser -e POSTGRES_PASSWORD=bot_logins -e POSTGRES_DB=discord_music_gws --tmpfs /var/lib/postgresql:size=2g postgres:18 >/dev/null
for i in $(seq 30); do docker exec lumi_test_pg pg_isready -U botuser >/dev/null 2>&1 && break; sleep 1; done; sleep 2
docker exec postgres_local pg_dump -U botuser -Fc discord_music_gws | docker exec -i lumi_test_pg pg_restore -U botuser -d discord_music_gws --no-owner 2>&1 | tail -2 || true
docker exec lumi_test_pg psql -U botuser -d discord_music_gws -qc "update ios_discord_webhooks set webhook_url='https://example.invalid/blocked', enabled=false; update ios_user_webhooks set webhook_url='https://example.invalid/blocked', enabled=false; delete from ios_push_tokens;"
sh "$H/restart.sh"
docker run --rm --network lumi-test -v "$H":/w python:3.12-slim python -I /w/mkusers.py
UID_=$(docker exec lumi_test_pg psql -U botuser -d discord_music_gws -Atc "select id from ios_users where username='rusttest'")
BID_=$(docker exec lumi_test_pg psql -U botuser -d discord_music_gws -Atc "select id from ios_users where username='rustmade1'")
OP=ca8a4c53-5603-472e-9287-5fb879f28090; TID=$(cat /proc/sys/kernel/random/uuid)
docker exec lumi_test_pg psql -U botuser -d discord_music_gws -qc "insert into ios_user_sessions(token_id,user_id,expires_at,device_name) values ('$TID','$OP',now()+interval '30 days','harness')"
docker run --rm --network lumi-test --env-file $HOME/Projects/Lumisound/ios-bridge/.env -v "$H":/w -e TID=$TID -e OP=$OP -e UID_=$UID_ -e BID_=$BID_ web-stack-ios-bridge-legacy python -c "
import json,os,sys; sys.path.insert(0,'/app'); from auth import create_token
t=json.load(open('/w/tokens.json')); t['op']=create_token(os.environ['OP'],os.environ['TID']); t['api']=os.environ.get('IOS_BRIDGE_API_KEY',''); t['admin']=os.environ.get('ADMIN_TOKEN',''); t['user_id']=os.environ['UID_']; t['b_id']=os.environ['BID_']
json.dump(t,open('/w/tokens.json','w')); print(sorted(t))"
