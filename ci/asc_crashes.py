#!/usr/bin/env python3
"""Prints the newest TestFlight crash reports for the app (crash point only).

Only the exception and the frames of the crashed thread are printed: the repository is
public, so tester comments, e-mail addresses and device identifiers are left out.
"""
import json, os, sys, time, urllib.error, urllib.request
import jwt

API = "https://api.appstoreconnect.apple.com/v1"
KEY_ID, ISSUER = os.environ["ASC_KEY_ID"], os.environ["ASC_ISSUER_ID"]
BUNDLE_ID = os.environ.get("BUNDLE_ID", "com.muratturna.loopnote")
LIMIT = int(os.environ.get("CRASH_LIMIT", "3"))


def call(path):
    now = int(time.time())
    tok = jwt.encode({"iss": ISSUER, "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"},
                     open(os.environ["ASC_KEY_PATH"]).read(), algorithm="ES256",
                     headers={"kid": KEY_ID, "typ": "JWT"})
    req = urllib.request.Request(API + path, headers={"Authorization": "Bearer " + tok})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        print(f"GET {path} failed: HTTP {e.code} {e.read().decode()[:300]}")
        return None


def summarize_ips(text):
    """Apple .ips crash logs: a JSON header line, then a JSON body."""
    lines = text.split("\n", 1)
    if len(lines) < 2:
        return None
    try:
        body = json.loads(lines[1])
    except ValueError:
        return None
    images = body.get("usedImages", [])
    out = []
    exc = body.get("exception", {})
    out.append(f"Exception: {exc.get('type')} {exc.get('signal', '')} {exc.get('subtype', '')}".strip())
    if body.get("termination"):
        t = body["termination"]
        out.append(f"Termination: {t.get('namespace')} {t.get('indicator', '')} {t.get('reasons', '')}")
    if body.get("asi"):
        out.append(f"Diagnostic: {json.dumps(body['asi'])[:600]}")
    for th in body.get("threads", []):
        if not th.get("triggered"):
            continue
        out.append(f"Crashed thread: {th.get('queue') or th.get('name') or ''}")
        for i, f in enumerate(th.get("frames", [])[:40]):
            img = images[f["imageIndex"]].get("name", "?") if f.get("imageIndex", -1) < len(images) else "?"
            sym = f.get("symbol", "")
            loc = f" ({f['sourceFile']}:{f.get('sourceLine')})" if f.get("sourceFile") else ""
            out.append(f"  {i:2} {img:28} {sym}{loc}")
    return "\n".join(out)


def summarize_text(text):
    keep, crashed = [], False
    for line in text.splitlines():
        if line.startswith(("Exception Type", "Exception Codes", "Termination Reason",
                            "Triggered by Thread", "Crashed Thread", "Application Specific")):
            keep.append(line)
        if "Crashed:" in line:
            crashed = True
            keep.append(line)
            continue
        if crashed:
            if not line.strip():
                break
            keep.append(line)
    return "\n".join(keep[:80])


apps = (call(f"/apps?filter[bundleId]={BUNDLE_ID}") or {}).get("data", [])
if not apps:
    sys.exit("App record not found")
app_id = apps[0]["id"]

subs = call(f"/apps/{app_id}/betaFeedbackCrashSubmissions?limit={LIMIT}&sort=-createdDate")
items = (subs or {}).get("data", [])
print(f"{len(items)} crash report(s)")
for s in items:
    a = s.get("attributes", {})
    print("=" * 80)
    print(f"{a.get('createdDate')}  build {a.get('buildNumber', '?')}  "
          f"{a.get('deviceModel', '')} iOS {a.get('osVersion', '')}")
    log = call(f"/betaFeedbackCrashSubmissions/{s['id']}/crashLog")
    text = ((log or {}).get("data") or {}).get("attributes", {}).get("logText", "")
    if not text:
        print("(no crash log attached yet)")
        continue
    print(summarize_ips(text) or summarize_text(text))
