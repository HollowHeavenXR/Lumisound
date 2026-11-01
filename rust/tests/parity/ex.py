import json, urllib.request, zipfile, io
tok = json.load(open("/w/tokens.json"))
def get(b):
    r = urllib.request.Request(b + "/user/export"); r.add_header("authorization", "Bearer " + tok["op"])
    with urllib.request.urlopen(r) as x: return x.read(), x.headers.get("content-type")
a, ca = get("http://lumi_py_test:8002"); b, cb = get("http://lumi_rs_test:8002")
print(ca, cb)
try:
    za, zb = zipfile.ZipFile(io.BytesIO(a)), zipfile.ZipFile(io.BytesIO(b))
    print([(i.filename, i.file_size) for i in za.infolist()]); print([(i.filename, i.file_size) for i in zb.infolist()])
    for n in za.namelist():
        x, y = za.read(n), zb.read(n) if n in zb.namelist() else b""
        if x != y:
            try:
                jx, jy = json.loads(x), json.loads(y); print(n, "json-equal" if jx == jy else "json-DIFF")
                if jx != jy:
                    for k in jx if isinstance(jx, dict) else []:
                        if jx.get(k) != jy.get(k): print("  key", k, str(jx.get(k))[:120], "|", str(jy.get(k))[:120])
            except Exception as e: print(n, "bytes differ", len(x), len(y))
except zipfile.BadZipFile:
    ja, jb = json.loads(a), json.loads(b); print("json-equal" if ja == jb else "json-DIFF")
    for k in ja:
        if ja.get(k) != jb.get(k): print("  key", k, str(ja.get(k))[:150], "|", str(jb.get(k))[:150])
