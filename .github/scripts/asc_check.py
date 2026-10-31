"""Before a TestFlight upload: register the app's bundle ID with Apple if it is new, and check
that its App Store Connect app exists (Apple only lets a person create that, on the website).

Reads ASC_KEY_PATH, ASC_KEY_ID, ASC_ISSUER_ID and BUNDLE_ID from the environment.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

import jwt

API = "https://api.appstoreconnect.apple.com/v1"


def token():
    now = int(time.time())
    with open(os.environ["ASC_KEY_PATH"]) as f:
        key = f.read()
    return jwt.encode(
        {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"},
        key,
        algorithm="ES256",
        headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"},
    )


def call(method, path, body=None):
    request = urllib.request.Request(
        API + path,
        method=method,
        data=None if body is None else json.dumps(body).encode(),
        headers={"Authorization": "Bearer " + token(), "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        detail = error.read().decode(errors="replace")
        print(f"::error::App Store Connect said {error.code} for {method} {path}: {detail}")
        if error.code == 401:
            print("::error::Check the ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_P8 secrets.")
        sys.exit(1)


def main():
    bundle_id = os.environ["BUNDLE_ID"]
    query = urllib.parse.quote(bundle_id)

    found = call("GET", f"/bundleIds?filter[identifier]={query}")["data"]
    if any(b["attributes"]["identifier"] == bundle_id for b in found):
        print(f"Bundle ID {bundle_id} is registered.")
    else:
        call("POST", "/bundleIds", {"data": {"type": "bundleIds", "attributes": {
            "identifier": bundle_id, "name": "Reset", "platform": "IOS"}}})
        print(f"Registered bundle ID {bundle_id}.")

    apps = call("GET", f"/apps?filter[bundleId]={query}")["data"]
    if not any(a["attributes"]["bundleId"] == bundle_id for a in apps):
        print(f"::error::No App Store Connect app for {bundle_id} yet. In App Store Connect, open Apps, "
              f"tap + then New App, pick the bundle ID {bundle_id}, then run this workflow again.")
        sys.exit(1)
    print("App Store Connect app found.")


if __name__ == "__main__":
    main()
