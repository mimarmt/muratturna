#!/usr/bin/env python3
"""Creates Loopnote Pro in App Store Connect (idempotent):
- subscription group "Loopnote Pro" with monthly and yearly auto-renewing subscriptions
  (yearly with a one-week free trial),
- a non-consumable "lifetime" purchase,
- names and descriptions in English, Turkish and German,
- prices set in USD and equalized by Apple for every other storefront,
- availability in all territories.

Product IDs must match App/Loopnote/Services/ProStore.swift.
"""
import json, os, sys, time, urllib.error, urllib.request
import jwt

API = "https://api.appstoreconnect.apple.com"
KEY_ID, ISSUER = os.environ["ASC_KEY_ID"], os.environ["ASC_ISSUER_ID"]
BUNDLE_ID = os.environ.get("BUNDLE_ID", "com.muratturna.loopnote")

GROUP_NAME = "Loopnote Pro"
SUBSCRIPTIONS = [
    {"id": "com.muratturna.loopnote.pro.monthly", "name": "Loopnote Pro Monthly", "period": "ONE_MONTH",
     "level": 2, "usd": "2.99", "trial": None,
     "loc": {"en-US": ("Loopnote Pro Monthly", "Unlimited notes, alarms and all features"),
             "tr": ("Loopnote Pro Aylık", "Sınırsız not, alarm ve tüm özellikler"),
             "de-DE": ("Loopnote Pro Monatlich", "Unbegrenzte Notizen, Alarme, alle Funktionen")}},
    {"id": "com.muratturna.loopnote.pro.yearly", "name": "Loopnote Pro Yearly", "period": "ONE_YEAR",
     "level": 1, "usd": "19.99", "trial": "ONE_WEEK",
     "loc": {"en-US": ("Loopnote Pro Yearly", "Unlimited notes, alarms and all features"),
             "tr": ("Loopnote Pro Yıllık", "Sınırsız not, alarm ve tüm özellikler"),
             "de-DE": ("Loopnote Pro Jährlich", "Unbegrenzte Notizen, Alarme, alle Funktionen")}},
]
LIFETIME = {"id": "com.muratturna.loopnote.pro.lifetime", "name": "Loopnote Pro Lifetime", "usd": "49.99",
            "loc": {"en-US": ("Loopnote Pro Lifetime", "One payment, all Pro features forever"),
                    "tr": ("Loopnote Pro Ömür Boyu", "Tek ödeme, tüm Pro özellikleri kalıcı"),
                    "de-DE": ("Loopnote Pro Lebenslang", "Einmal zahlen, alle Pro-Funktionen")}}


def token():
    now = int(time.time())
    return jwt.encode({"iss": ISSUER, "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"},
                      open(os.environ["ASC_KEY_PATH"]).read(), algorithm="ES256",
                      headers={"kid": KEY_ID, "typ": "JWT"})


def call(method, path, body=None, quiet409=True):
    url = path if path.startswith("http") else API + path
    req = urllib.request.Request(url, method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Authorization": "Bearer " + token(),
                                          "Content-Type": "application/json"})
    for attempt in range(4):
        try:
            with urllib.request.urlopen(req, timeout=90) as r:
                raw = r.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as e:
            detail = " ".join(e.read().decode().split())[:300]
            if e.code == 409 and quiet409:
                return {"_conflict": detail}
            if e.code >= 500 and attempt < 3:
                # Apple's API returns occasional 500s under load; back off and retry.
                time.sleep(2 * (attempt + 1))
                req = urllib.request.Request(url, method=method,
                                             data=json.dumps(body).encode() if body is not None else None,
                                             headers={"Authorization": "Bearer " + token(),
                                                      "Content-Type": "application/json"})
                continue
            print(f"!! {method} {path} -> HTTP {e.code}: {detail}")
            return None
    return None


def get_all(path):
    out, url = [], path
    while url:
        page = call("GET", url)
        if not page:
            break
        out += page.get("data", [])
        url = page.get("links", {}).get("next")
    return out


def rel(type_, id_):
    return {"data": {"type": type_, "id": id_}}


apps = call("GET", f"/v1/apps?filter[bundleId]={BUNDLE_ID}")["data"]
if not apps:
    sys.exit("App record not found")
APP = apps[0]["id"]
territories = [t["id"] for t in get_all("/v1/territories?limit=200")]
print(f"App {APP}; {len(territories)} territories")

# --- Subscription group -------------------------------------------------------------------
groups = get_all(f"/v1/apps/{APP}/subscriptionGroups?limit=50")
group = next((g for g in groups if g["attributes"]["referenceName"] == GROUP_NAME), None)
if not group:
    group = call("POST", "/v1/subscriptionGroups", {"data": {
        "type": "subscriptionGroups", "attributes": {"referenceName": GROUP_NAME},
        "relationships": {"app": rel("apps", APP)}}})["data"]
    print("Created subscription group")
GID = group["id"]
have = {l["attributes"]["locale"] for l in get_all(f"/v1/subscriptionGroups/{GID}/subscriptionGroupLocalizations")}
for locale in ("en-US", "tr", "de-DE"):
    if locale not in have:
        call("POST", "/v1/subscriptionGroupLocalizations", {"data": {
            "type": "subscriptionGroupLocalizations",
            "attributes": {"name": GROUP_NAME, "locale": locale},
            "relationships": {"subscriptionGroup": rel("subscriptionGroups", GID)}}})
        print(f"  group name {locale}")

# --- Subscriptions ---------------------------------------------------------------------------
existing = {s["attributes"]["productId"]: s for s in get_all(f"/v1/subscriptionGroups/{GID}/subscriptions?limit=50")}
for spec in SUBSCRIPTIONS:
    sub = existing.get(spec["id"])
    if not sub:
        res = call("POST", "/v1/subscriptions", {"data": {
            "type": "subscriptions",
            "attributes": {"name": spec["name"], "productId": spec["id"],
                           "subscriptionPeriod": spec["period"], "groupLevel": spec["level"],
                           "familySharable": False},
            "relationships": {"group": rel("subscriptionGroups", GID)}}})
        if not res or "data" not in res:
            continue
        sub = res["data"]
        print(f"Created subscription {spec['id']}")
    SID = sub["id"]

    have = {l["attributes"]["locale"] for l in get_all(f"/v1/subscriptions/{SID}/subscriptionLocalizations")}
    for locale, (name, desc) in spec["loc"].items():
        if locale not in have:
            call("POST", "/v1/subscriptionLocalizations", {"data": {
                "type": "subscriptionLocalizations",
                "attributes": {"name": name, "description": desc, "locale": locale},
                "relationships": {"subscription": rel("subscriptions", SID)}}})
            print(f"  {spec['id']} text {locale}")

    # Availability in every territory (a 409 means it is already set).
    if True:
        call("POST", "/v1/subscriptionAvailabilities", {"data": {
            "type": "subscriptionAvailabilities", "attributes": {"availableInNewTerritories": True},
            "relationships": {"subscription": rel("subscriptions", SID),
                              "availableTerritories": {"data": [{"type": "territories", "id": t}
                                                                for t in territories]}}}})

    # Prices: the USD price point, then Apple's equalized price for every other storefront.
    priced = {p["relationships"]["territory"]["data"]["id"]
              for p in get_all(f"/v1/subscriptions/{SID}/prices?include=territory&limit=200")
              if p.get("relationships", {}).get("territory", {}).get("data")}
    points = get_all(f"/v1/subscriptions/{SID}/pricePoints?filter[territory]=USA&limit=200")
    usd = next((p for p in points if p["attributes"]["customerPrice"] == spec["usd"]), None)
    if not usd:
        print(f"!! no USD price point {spec['usd']} for {spec['id']}")
        continue
    targets = [("USA", usd["id"])]
    for eq in get_all(f"/v1/subscriptionPricePoints/{usd['id']}/equalizations?include=territory&limit=200"):
        terr = eq.get("relationships", {}).get("territory", {}).get("data", {}).get("id")
        if terr:
            targets.append((terr, eq["id"]))
    added = 0
    for terr, point in targets:
        if terr in priced:
            continue
        if call("POST", "/v1/subscriptionPrices", {"data": {
                "type": "subscriptionPrices", "attributes": {"preserveCurrentPrice": False},
                "relationships": {"subscription": rel("subscriptions", SID),
                                  "subscriptionPricePoint": rel("subscriptionPricePoints", point),
                                  "territory": rel("territories", terr)}}}) is not None:
            added += 1
    print(f"  {spec['id']}: prices set in {added} new storefronts ({len(targets)} total)")

    if spec["trial"]:
        offers = get_all(f"/v1/subscriptions/{SID}/introductoryOffers?include=territory&limit=200")
        offered = {o["relationships"]["territory"]["data"]["id"] for o in offers
                   if o.get("relationships", {}).get("territory", {}).get("data")}
        made = 0
        for terr, _ in targets:
            if terr in offered:
                continue
            if call("POST", "/v1/subscriptionIntroductoryOffers", {"data": {
                    "type": "subscriptionIntroductoryOffers",
                    "attributes": {"duration": spec["trial"], "offerMode": "FREE_TRIAL", "numberOfPeriods": 1},
                    "relationships": {"subscription": rel("subscriptions", SID),
                                      "territory": rel("territories", terr)}}}) is not None:
                made += 1
        print(f"  {spec['id']}: free trial added in {made} storefronts")

# --- Lifetime (non-consumable) ----------------------------------------------------------------
iaps = get_all(f"/v1/apps/{APP}/inAppPurchasesV2?filter[productId]={LIFETIME['id']}")
if iaps:
    iap = iaps[0]
else:
    res = call("POST", "/v2/inAppPurchases", {"data": {
        "type": "inAppPurchases",
        "attributes": {"name": LIFETIME["name"], "productId": LIFETIME["id"],
                       "inAppPurchaseType": "NON_CONSUMABLE", "familySharable": False},
        "relationships": {"app": rel("apps", APP)}}})
    iap = res["data"] if res and "data" in res else None
    if iap:
        print(f"Created in-app purchase {LIFETIME['id']}")
if iap:
    IID = iap["id"]
    have = {l["attributes"]["locale"] for l in get_all(f"/v2/inAppPurchases/{IID}/inAppPurchaseLocalizations")}
    for locale, (name, desc) in LIFETIME["loc"].items():
        if locale not in have:
            call("POST", "/v1/inAppPurchaseLocalizations", {"data": {
                "type": "inAppPurchaseLocalizations",
                "attributes": {"name": name, "description": desc, "locale": locale},
                "relationships": {"inAppPurchaseV2": rel("inAppPurchases", IID)}}})
            print(f"  lifetime text {locale}")
    call("POST", "/v1/inAppPurchaseAvailabilities", {"data": {
        "type": "inAppPurchaseAvailabilities", "attributes": {"availableInNewTerritories": True},
        "relationships": {"inAppPurchase": rel("inAppPurchases", IID),
                          "availableTerritories": {"data": [{"type": "territories", "id": t}
                                                            for t in territories]}}}})
    points = get_all(f"/v2/inAppPurchases/{IID}/pricePoints?filter[territory]=USA&limit=200")
    usd = next((p for p in points if p["attributes"]["customerPrice"] == LIFETIME["usd"]), None)
    if usd:
        res = call("POST", "/v1/inAppPurchasePriceSchedules", {
            "data": {"type": "inAppPurchasePriceSchedules",
                     "relationships": {"inAppPurchase": rel("inAppPurchases", IID),
                                       "baseTerritory": rel("territories", "USA"),
                                       "manualPrices": {"data": [{"type": "inAppPurchasePrices", "id": "${p0}"}]}}},
            "included": [{"type": "inAppPurchasePrices", "id": "${p0}", "attributes": {"startDate": None},
                          "relationships": {"inAppPurchasePricePoint": rel("inAppPurchasePricePoints", usd["id"])}}]})
        print(f"  lifetime price {'set' if res is not None else 'NOT set'} (USD {LIFETIME['usd']}, others equalized)")
    else:
        print(f"!! no USD price point {LIFETIME['usd']} for lifetime")

# --- Summary -----------------------------------------------------------------------------------
print("\nState:")
for s in get_all(f"/v1/subscriptionGroups/{GID}/subscriptions?limit=50"):
    print(f"  {s['attributes']['productId']}: {s['attributes'].get('state')}")
for i in get_all(f"/v1/apps/{APP}/inAppPurchasesV2?limit=50"):
    print(f"  {i['attributes']['productId']}: {i['attributes'].get('state')}")
