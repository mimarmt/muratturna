#!/usr/bin/env python3
"""App Store distribution signing through the App Store Connect API.

  setup    Register the bundle ID if needed, create a temporary Apple Distribution
           certificate and an App Store provisioning profile, write a .p12 and the
           profile to disk, and export their details to $GITHUB_ENV.
  cleanup  Delete the temporary profile and certificate (keeps the account under
           Apple's certificate limit; already-uploaded builds are not affected).

Requires: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH, BUNDLE_ID, RUNNER_TEMP.
"""
import base64, json, os, secrets, sys, time, urllib.error, urllib.request
import jwt
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives.serialization import pkcs12
from cryptography.x509.oid import NameOID

API = "https://api.appstoreconnect.apple.com/v1"
KEY_ID, ISSUER = os.environ["ASC_KEY_ID"], os.environ["ASC_ISSUER_ID"]
BUNDLE_ID = os.environ.get("BUNDLE_ID", "com.muratturna.loopnote")
TMP = os.environ.get("RUNNER_TEMP", "/tmp")
STATE = os.path.join(TMP, "asc_signing_state.json")


def token():
    pem = open(os.environ["ASC_KEY_PATH"]).read()
    now = int(time.time())
    return jwt.encode({"iss": ISSUER, "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"},
                      pem, algorithm="ES256", headers={"kid": KEY_ID, "typ": "JWT"})


def call(method, path, body=None):
    req = urllib.request.Request(API + path, method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Authorization": "Bearer " + token(),
                                          "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        detail = e.read().decode()[:1500]
        raise SystemExit(f"{method} {path} failed: HTTP {e.code}\n{detail}")


def env(name, value, secret=False):
    if secret:
        print(f"::add-mask::{value}")
    with open(os.environ["GITHUB_ENV"], "a") as f:
        f.write(f"{name}={value}\n")


def ensure_bundle(identifier, name):
    found = call("GET", f"/bundleIds?filter[identifier]={identifier}&filter[platform]=IOS").get("data", [])
    found = [b for b in found if b["attributes"]["identifier"] == identifier]
    if found:
        print(f"Bundle ID {identifier} already registered")
        return found[0]["id"]
    bid = call("POST", "/bundleIds", {"data": {"type": "bundleIds", "attributes": {
        "identifier": identifier, "name": name, "platform": "IOS"}}})["data"]["id"]
    print(f"Registered bundle ID {identifier}")
    return bid


def setup():
    targets = [(BUNDLE_ID, "Loopnote", "PROFILE_NAME")]
    for extra in filter(None, os.environ.get("EXTRA_BUNDLE_IDS", "").split(",")):
        ident, envname = extra.split("=")
        targets.append((ident.strip(), "Loopnote " + ident.split(".")[-1], envname.strip()))
    bundles = [(ident, ensure_bundle(ident, name), envname) for ident, name, envname in targets]

    # Temporary distribution certificate
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    csr = (x509.CertificateSigningRequestBuilder()
           .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Loopnote CI"),
                                    x509.NameAttribute(NameOID.COUNTRY_NAME, "TR")]))
           .sign(key, hashes.SHA256()))
    csr_pem = csr.public_bytes(serialization.Encoding.PEM).decode()
    cert = call("POST", "/certificates", {"data": {"type": "certificates", "attributes": {
        "certificateType": "DISTRIBUTION", "csrContent": csr_pem}}})["data"]
    cert_id = cert["id"]
    state = {"cert": cert_id, "profiles": []}
    json.dump(state, open(STATE, "w"))
    der = base64.b64decode(cert["attributes"]["certificateContent"])
    print(f"Created distribution certificate {cert_id}")

    password = secrets.token_urlsafe(24)
    p12 = pkcs12.serialize_key_and_certificates(
        b"Loopnote CI", key, x509.load_der_x509_certificate(der), None,
        serialization.BestAvailableEncryption(password.encode()))
    p12_path = os.path.join(TMP, "dist.p12")
    open(p12_path, "wb").write(p12)

    # One App Store provisioning profile per bundle
    pdir = os.path.expanduser("~/Library/MobileDevice/Provisioning Profiles")
    os.makedirs(pdir, exist_ok=True)
    mapping = {}
    run = os.environ.get("GITHUB_RUN_ID", str(int(time.time())))
    for ident, bundle, envname in bundles:
        name = f"Loopnote CI {run} {ident.split('.')[-1]}"
        prof = call("POST", "/profiles", {"data": {"type": "profiles",
            "attributes": {"name": name, "profileType": "IOS_APP_STORE"},
            "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": bundle}},
                              "certificates": {"data": [{"type": "certificates", "id": cert_id}]}}}})["data"]
        state["profiles"].append(prof["id"])
        json.dump(state, open(STATE, "w"))
        open(os.path.join(pdir, f"{prof['attributes']['uuid']}.mobileprovision"), "wb").write(
            base64.b64decode(prof["attributes"]["profileContent"]))
        print(f"Created provisioning profile '{name}'")
        env(envname, name)
        mapping[ident] = name

    apps = call("GET", f"/apps?filter[bundleId]={BUNDLE_ID}").get("data", [])
    exists = any(a["attributes"]["bundleId"] == BUNDLE_ID for a in apps)
    print("App Store Connect app record:", "found" if exists else "NOT FOUND")

    env("P12_PATH", p12_path)
    env("P12_PASSWORD", password, secret=True)
    env("PROFILE_MAP", json.dumps(mapping))
    env("APP_RECORD_EXISTS", "yes" if exists else "no")


def cleanup():
    if not os.path.exists(STATE):
        return
    st = json.load(open(STATE))
    items = [("profiles", p) for p in st.get("profiles", [])]
    if st.get("cert"):
        items.append(("certificates", st["cert"]))
    for kind, ident in items:
        try:
            call("DELETE", f"/{kind}/{ident}")
            print(f"Deleted {kind[:-1]} {ident}")
        except SystemExit as e:
            print(f"warning: {e}")


if __name__ == "__main__":
    {"setup": setup, "cleanup": cleanup}[sys.argv[1]]()
