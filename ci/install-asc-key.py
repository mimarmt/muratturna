#!/usr/bin/env python3
"""Writes the App Store Connect API key from $ASC_KEY_P8 as a well-formed PEM file
and verifies it against the App Store Connect API.

Keys pasted on a phone often lose their line breaks or gain stray characters,
so the base64 body is extracted and re-wrapped at 64 columns.
"""
import base64, json, os, re, sys, time, urllib.request, urllib.error

raw = os.environ.get("ASC_KEY_P8", "")
key_id = os.environ["ASC_KEY_ID"]
issuer = os.environ["ASC_ISSUER_ID"]
out_dir = os.environ["RUNNER_TEMP"] + "/keys"

if not raw.strip():
    sys.exit("ASC_KEY_P8 secret is empty or missing.")

body = re.sub(r"-----(BEGIN|END)[A-Z ]*-----", "", raw)
body = re.sub(r"[^A-Za-z0-9+/=]", "", body)
try:
    der = base64.b64decode(body, validate=True)
except Exception as e:
    sys.exit(f"ASC_KEY_P8 is not valid base64 after cleanup: {e}")
print(f"Key body: {len(body)} base64 chars, {len(der)} DER bytes")

pem = "-----BEGIN PRIVATE KEY-----\n" + "\n".join(body[i:i + 64] for i in range(0, len(body), 64)) + "\n-----END PRIVATE KEY-----\n"
os.makedirs(out_dir, exist_ok=True)
path = f"{out_dir}/AuthKey_{key_id}.p8"
with open(path, "w") as f:
    f.write(pem)
with open(os.environ["GITHUB_ENV"], "a") as f:
    f.write(f"ASC_KEY_PATH={path}\n")

# Verify: sign a JWT (ES256) and list apps.
import jwt  # PyJWT
now = int(time.time())
token = jwt.encode({"iss": issuer, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"},
                   pem, algorithm="ES256", headers={"kid": key_id, "typ": "JWT"})
req = urllib.request.Request("https://api.appstoreconnect.apple.com/v1/apps?limit=200&fields[apps]=bundleId,name",
                             headers={"Authorization": f"Bearer {token}"})
try:
    data = json.load(urllib.request.urlopen(req, timeout=30))
except urllib.error.HTTPError as e:
    sys.exit(f"App Store Connect rejected the key: HTTP {e.code} {e.read().decode()[:400]}")
apps = [(a["attributes"]["name"], a["attributes"]["bundleId"]) for a in data.get("data", [])]
print("API key OK. Apps in this account:")
for name, bid in apps:
    print(f"  - {name}  ({bid})")
print("LOOPNOTE_APP_EXISTS=" + ("yes" if any(b == "com.muratturna.loopnote" for _, b in apps) else "no"))
