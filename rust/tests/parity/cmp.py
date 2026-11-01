"""Compare Python vs Rust bridge responses. Usage: cmp.py <cases.json>
case: {"m":"GET","p":"/path","b":{...}|null,"auth":"user"|"b"|"op"|"none"|"api"|"admin","ignore":["key",...],"both":bool}
Paths may use {user_id}/{b_id} placeholders from tokens.json."""
import json, sys, urllib.request, os
PY, RS = "http://lumi_py_test:8002", "http://lumi_rs_test:8002"
tok = json.load(open("/w/tokens.json")) if os.path.exists("/w/tokens.json") else {}
def call(base, c):
    data = json.dumps(c["b"]).encode() if c.get("b") is not None else None
    p = c["p"].replace("{user_id}", tok.get("user_id") or "").replace("{b_id}", tok.get("b_id") or "")
    r = urllib.request.Request(base + p, data=data, method=c.get("m", "GET"))
    if data: r.add_header("content-type", "application/json")
    a = c.get("auth", "user")
    if a in tok: r.add_header("authorization", "Bearer " + tok[a])
    for k, v in c.get("h", {}).items(): r.add_header(k, v)
    try:
        with urllib.request.urlopen(r, timeout=90) as resp: st, body, ct = resp.status, resp.read(), resp.headers.get("content-type", "")
    except urllib.error.HTTPError as e: st, body, ct = e.code, e.read(), e.headers.get("content-type", "")
    try: body = json.loads(body)
    except Exception: body = ("<%d bytes>" % len(body))
    return st, body
def scrub(v, ign):
    if isinstance(v, dict): return {k: scrub(x, ign) for k, x in v.items() if k not in ign}
    if isinstance(v, list): return [scrub(x, ign) for x in v]
    return v
def diff(a, b, path=""):
    out = []
    if type(a) != type(b) and not (isinstance(a,(int,float)) and isinstance(b,(int,float))): return [f"{path}: type {type(a).__name__}={str(a)[:80]} vs {type(b).__name__}={str(b)[:80]}"]
    if isinstance(a, dict):
        for k in sorted(set(a) | set(b)):
            if k not in a: out.append(f"{path}.{k}: only rust ({str(b[k])[:60]})")
            elif k not in b: out.append(f"{path}.{k}: only py ({str(a[k])[:60]})")
            else: out += diff(a[k], b[k], f"{path}.{k}")
    elif isinstance(a, list):
        if len(a) != len(b): out.append(f"{path}: len {len(a)} vs {len(b)}")
        for i, (x, y) in enumerate(zip(a, b)): out += diff(x, y, f"{path}[{i}]")
    elif a != b: out.append(f"{path}: {str(a)[:80]!r} vs {str(b)[:80]!r}")
    return out
cases = json.load(open(sys.argv[1]))
bad = 0
for c in cases:
    ign = set(c.get("ignore", []))
    if c.get("m", "GET") != "GET" and not c.get("both"):
        st, b = call(RS, c); print(f"RS-ONLY {c.get('m')} {c['p']} -> {st} {str(b)[:200]}"); continue
    s1, b1 = call(PY, c); s2, b2 = call(RS, c)
    d = diff(scrub(b1, ign), scrub(b2, ign))
    if s1 != s2: d.insert(0, f"status {s1} vs {s2}")
    if d: bad += 1; print(f"DIFF {c.get('m','GET')} {c['p']}:"); [print("   ", x) for x in d[:15]]
    else: print(f"ok   {c.get('m','GET')} {c['p']} ({s1})")
print(f"{len(cases)} cases, {bad} differ")
