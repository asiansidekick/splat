"""Prints the newest TestFlight crash reports for Reset, so a crash can be read without a Mac.

Reads ASC_KEY_PATH, ASC_KEY_ID, ASC_ISSUER_ID and BUNDLE_ID from the environment.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request

import jwt

API = "https://api.appstoreconnect.apple.com"


def token():
    now = int(time.time())
    with open(os.environ["ASC_KEY_PATH"]) as f:
        key = f.read()
    return jwt.encode(
        {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"},
        key, algorithm="ES256", headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"})


def get(path):
    url = path if path.startswith("http") else API + path
    request = urllib.request.Request(url, headers={"Authorization": "Bearer " + token()})
    try:
        with urllib.request.urlopen(request) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        print(f"HTTP {error.code} for {path}: {error.read().decode(errors='replace')[:500]}")
        return None


def main():
    apps = get("/v1/apps?filter[bundleId]=" + os.environ["BUNDLE_ID"])
    app = apps["data"][0]["id"]
    subs = get(f"/v1/apps/{app}/betaFeedbackCrashSubmissions?limit=5&sort=-createdDate")
    if not subs or not subs.get("data"):
        print("No crash submissions found.")
        return
    for sub in subs["data"]:
        a = sub["attributes"]
        print("=" * 70)
        print(sub["id"], a.get("createdDate"), a.get("buildBundleId"), a.get("appPlatform"), a.get("deviceModel"), a.get("osVersion"))
        log = get(f"/v1/betaFeedbackCrashSubmissions/{sub['id']}/crashLog")
        if log:
            print(log["data"]["attributes"].get("logText", "")[:12000])


main()
