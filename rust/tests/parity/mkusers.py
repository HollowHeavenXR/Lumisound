import json, urllib.request
def post(p, b):
    r = urllib.request.Request("http://lumi_py_test:8002" + p, data=json.dumps(b).encode(), method="POST"); r.add_header("content-type", "application/json")
    try:
        with urllib.request.urlopen(r) as x: return json.loads(x.read())
    except urllib.error.HTTPError as e: return {"err": e.code, "body": e.read().decode()}
pw = "Tst-Rust-Port-9137"; t = {}
for key, name in (("user", "rusttest"), ("b", "rustmade1")):
    r = post("/auth/register", {"username": name, "email": name + "@gmail.com", "password": pw, "device_name": "harness"})
    if not (r.get("access_token") or r.get("token")): r = post("/auth/login", {"username": name, "password": pw, "device_name": "harness"})
    t[key] = r.get("access_token") or r.get("token"); t[key + "_id"] = (r.get("user") or {}).get("id")
json.dump(t, open("/w/tokens.json", "w")); print({k: bool(v) for k, v in t.items()})
