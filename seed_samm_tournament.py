#!/usr/bin/env python3
"""Seed the Samm Simon 251 KM tournament on home.renovation.reviews.

Run this AFTER deploying plugin v0.19.4 (which adds the admin
tournament create endpoint). Idempotent: re-running is a no-op
because the slug constraint is unique.

Usage:
    python3 seed_samm_tournament.py
"""
import urllib.request, urllib.parse, json, sys

API_KEY = "ccc3280915ac9c2eec96a61ebb8882726b9d6c0e848fb58070aed198921fd056"
HOST = "https://home.renovation.reviews"
UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/124"

HDR = {
    "Api-Key": API_KEY,
    "Api-Username": "system",
    "User-Agent": UA,
    "Accept": "application/json",
    "Content-Type": "application/x-www-form-urlencoded",
}

PAYLOAD = {
    "slug": "samm-simon-251km-2026",
    "name": "Samm Simon — 251 KM Run for Cancer Charities",
    "description": (
        "Samm Simon is running 251 KM to raise money for cancer research. "
        "From May 10 through May 17, 2026, every post tagged #samm251 "
        "earns 2x $RENO plus a 251 bonus per qualifying post — every "
        "thread you start, every reply you write, pushes Samm closer to "
        "the finish line and adds to the donation total. Participate, "
        "share renovation tips that help homeowners, and put your $RENO "
        "where the cause is."
    ),
    "tournament_type": "monthly_theme",
    "starts_at": "2026-05-10T00:00:00-04:00",
    "ends_at": "2026-05-17T23:59:59-04:00",
    "status": "active",  # already start active so it's visible immediately
    "prize_pool": 251000,  # 251,000 $RENO prize pool — narrative number
}

def main():
    body = urllib.parse.urlencode(PAYLOAD).encode("utf-8")
    url = f"{HOST}/admin/coin-engine/tournaments.json"
    req = urllib.request.Request(url, data=body, headers=HDR, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            print(f"  HTTP {r.getcode()}")
            print(json.dumps(json.loads(r.read()), indent=2))
    except urllib.error.HTTPError as e:
        body2 = e.read().decode("utf-8", errors="replace")
        if e.code == 409:
            print(f"  HTTP 409: tournament already exists (idempotent re-run, OK)")
            print(f"  body: {body2[:200]}")
            return 0
        print(f"  HTTP {e.code}: {body2[:500]}")
        return 1

    # Verify via the public list endpoint
    print("\n=== verify via public /coin-engine/identity/tournaments.json ===")
    r = urllib.request.urlopen(urllib.request.Request(
        f"{HOST}/coin-engine/identity/tournaments.json",
        headers={"User-Agent": UA, "Accept": "application/json"}), timeout=15)
    d = json.loads(r.read())
    for t in d.get("tournaments", []):
        print(f"  {t.get('slug'):30s} {t.get('status'):10s} {t.get('starts_at')} -> {t.get('ends_at')}")
    return 0

if __name__ == "__main__":
    sys.exit(main())
