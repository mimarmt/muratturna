#!/usr/bin/env python3
"""Ensures an internal TestFlight group exists for the app, receives every build,
and contains the team's Account Holder and Admin users. Idempotent."""
import json, os, sys, time, urllib.error, urllib.request
import jwt

API = "https://api.appstoreconnect.apple.com/v1"
KEY_ID, ISSUER = os.environ["ASC_KEY_ID"], os.environ["ASC_ISSUER_ID"]
BUNDLE_ID = os.environ.get("BUNDLE_ID", "com.muratturna.loopnote")
GROUP = "Internal"


def call(method, path, body=None, ok=(200, 201, 204)):
    now = int(time.time())
    tok = jwt.encode({"iss": ISSUER, "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"},
                     open(os.environ["ASC_KEY_PATH"]).read(), algorithm="ES256",
                     headers={"kid": KEY_ID, "typ": "JWT"})
    req = urllib.request.Request(API + path, method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Authorization": "Bearer " + tok, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        detail = e.read().decode()[:800]
        if e.code == 409:
            print(f"note: {method} {path} -> 409 (already done?) {detail[:200]}")
            return {}
        sys.exit(f"{method} {path} failed: HTTP {e.code}\n{detail}")


apps = call("GET", f"/apps?filter[bundleId]={BUNDLE_ID}")["data"]
if not apps:
    sys.exit("App record not found")
app_id = apps[0]["id"]

groups = call("GET", f"/apps/{app_id}/betaGroups?limit=50")["data"]
group = next((g for g in groups if g["attributes"].get("isInternalGroup")), None)
if group:
    print(f"Internal group exists: {group['attributes']['name']}")
else:
    group = call("POST", "/betaGroups", {"data": {"type": "betaGroups",
        "attributes": {"name": GROUP, "isInternalGroup": True, "hasAccessToAllBuilds": True},
        "relationships": {"app": {"data": {"type": "apps", "id": app_id}}}}})["data"]
    print(f"Created internal group {GROUP}")
gid = group["id"]

members = {t["attributes"].get("email", "").lower()
           for t in call("GET", f"/betaGroups/{gid}/betaTesters?limit=200").get("data", [])}
users = call("GET", "/users?limit=200")["data"]
for u in users:
    a = u["attributes"]
    roles = set(a.get("roles", []))
    if not roles & {"ACCOUNT_HOLDER", "ADMIN"}:
        continue
    email = a.get("username") or a.get("email")
    who = f"{a.get('firstName', '')} {a.get('lastName', '')}".strip()
    if not email:
        continue
    if email.lower() in members:
        print(f"Tester already in group: {who}")
        continue
    call("POST", "/betaTesters", {"data": {"type": "betaTesters",
        "attributes": {"email": email, "firstName": a.get("firstName", ""), "lastName": a.get("lastName", "")},
        "relationships": {"betaGroups": {"data": [{"type": "betaGroups", "id": gid}]}}}})
    print(f"Added tester: {who}")
print("TestFlight internal testing is ready.")
