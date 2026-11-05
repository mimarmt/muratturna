#!/usr/bin/env python3
"""Uploads paywall.png as the App Review screenshot of every Loopnote Pro product that lacks one,
then prints each product's state. Idempotent."""
import hashlib, json, os, sys, time, urllib.error, urllib.request
import jwt

API = "https://api.appstoreconnect.apple.com"
KEY_ID, ISSUER = os.environ["ASC_KEY_ID"], os.environ["ASC_ISSUER_ID"]
BUNDLE_ID = os.environ.get("BUNDLE_ID", "com.muratturna.loopnote")
IMAGE = os.environ.get("SCREENSHOT", "paywall.png")


def call(method, path, body=None):
    now = int(time.time())
    tok = jwt.encode({"iss": ISSUER, "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"},
                     open(os.environ["ASC_KEY_PATH"]).read(), algorithm="ES256",
                     headers={"kid": KEY_ID, "typ": "JWT"})
    for attempt in range(4):
        req = urllib.request.Request(API + path, method=method,
                                     data=json.dumps(body).encode() if body is not None else None,
                                     headers={"Authorization": "Bearer " + tok, "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=90) as r:
                raw = r.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as e:
            detail = " ".join(e.read().decode().split())[:300]
            if e.code >= 500 and attempt < 3:
                time.sleep(2 * (attempt + 1))
                continue
            if e.code == 404:
                return None
            print(f"!! {method} {path} -> HTTP {e.code}: {detail}")
            return None


data = open(IMAGE, "rb").read()
checksum = hashlib.md5(data).hexdigest()


def upload(kind, owner_rel, owner_type, owner_id):
    """kind: subscriptionAppStoreReviewScreenshots or inAppPurchaseAppStoreReviewScreenshots."""
    res = call("POST", f"/v1/{kind}", {"data": {
        "type": kind, "attributes": {"fileName": "paywall.png", "fileSize": len(data)},
        "relationships": {owner_rel: {"data": {"type": owner_type, "id": owner_id}}}}})
    if not res:
        return False
    shot = res["data"]
    for op in shot["attributes"].get("uploadOperations") or []:
        chunk = data[op["offset"]:op["offset"] + op["length"]]
        headers = {h["name"]: h["value"] for h in op.get("requestHeaders", [])}
        req = urllib.request.Request(op["url"], method=op["method"], data=chunk, headers=headers)
        with urllib.request.urlopen(req, timeout=120) as r:
            r.read()
    done = call("PATCH", f"/v1/{kind}/{shot['id']}", {"data": {
        "type": kind, "id": shot["id"],
        "attributes": {"uploaded": True, "sourceFileChecksum": checksum}}})
    return done is not None


app = call("GET", f"/v1/apps?filter[bundleId]={BUNDLE_ID}")["data"][0]["id"]

for group in call("GET", f"/v1/apps/{app}/subscriptionGroups?limit=50")["data"]:
    for sub in call("GET", f"/v1/subscriptionGroups/{group['id']}/subscriptions?limit=50")["data"]:
        pid = sub["attributes"]["productId"]
        existing = call("GET", f"/v1/subscriptions/{sub['id']}/appStoreReviewScreenshot")
        if existing and existing.get("data"):
            print(f"{pid}: screenshot already present")
            continue
        ok = upload("subscriptionAppStoreReviewScreenshots", "subscription", "subscriptions", sub["id"])
        print(f"{pid}: screenshot {'uploaded' if ok else 'FAILED'}")

for iap in call("GET", f"/v1/apps/{app}/inAppPurchasesV2?limit=50")["data"]:
    pid = iap["attributes"]["productId"]
    existing = call("GET", f"/v2/inAppPurchases/{iap['id']}/appStoreReviewScreenshot")
    if existing and existing.get("data"):
        print(f"{pid}: screenshot already present")
        continue
    ok = upload("inAppPurchaseAppStoreReviewScreenshots", "inAppPurchaseV2", "inAppPurchases", iap["id"])
    print(f"{pid}: screenshot {'uploaded' if ok else 'FAILED'}")

time.sleep(20)
print("\nState:")
for group in call("GET", f"/v1/apps/{app}/subscriptionGroups?limit=50")["data"]:
    for sub in call("GET", f"/v1/subscriptionGroups/{group['id']}/subscriptions?limit=50")["data"]:
        print(f"  {sub['attributes']['productId']}: {sub['attributes'].get('state')}")
for iap in call("GET", f"/v1/apps/{app}/inAppPurchasesV2?limit=50")["data"]:
    print(f"  {iap['attributes']['productId']}: {iap['attributes'].get('state')}")
