"""Long-running job checks against one bridge: jobs.py <base> <kind> <file>
kind: transcribe | stems | fingerprint"""
import json, sys, time, urllib.request, urllib.parse
tok = json.load(open("/w/tokens.json"))
base, kind, f = sys.argv[1], sys.argv[2], sys.argv[3]
def req(p, data=None, method="GET", who="user", ct="audio/mpeg"):
    r = urllib.request.Request(base + p, data=data, method=method); r.add_header("authorization", "Bearer " + tok[who])
    if data is not None: r.add_header("content-type", ct)
    try:
        with urllib.request.urlopen(r, timeout=120) as x: return x.status, x.read()
    except urllib.error.HTTPError as e: return e.code, e.read()
audio = open(f, "rb").read()
if kind == "fingerprint":
    print(req("/api/fingerprint/identify?ext=mp3", audio, "POST", who="op")); sys.exit()
start = {"transcribe": "/user/intelligence/lyrics-transcribe?" + urllib.parse.urlencode({"title": "Beneath the Mask", "artist": "Lyn"}),
         "stems": "/api/stem-separation?title=Beneath%20the%20Mask"}[kind]
st, b = req(start, audio, "POST"); print(st, b[:200]); jid = json.loads(b)["job_id"]
status = {"transcribe": "/user/intelligence/lyrics-transcribe/status?job_id=", "stems": "/api/stem-separation/status?job_id="}[kind] + jid
for _ in range(240):
    time.sleep(5)
    s = json.loads(req(status)[1])
    if s["status"] not in ("pending", "running"): print(json.dumps(s)[:800]); break
if kind == "stems" and s["status"] == "done":
    for stem in ("vocals", "instrumental"):
        st, b = req(f"/api/stem-separation/result?job_id={jid}&stem={stem}"); print(stem, st, len(b))
