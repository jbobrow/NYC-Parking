#!/usr/bin/env python3
"""
build_web_data.py — Export segments.db to a compact JSON file for the website map.

Usage
-----
    python3 scripts/build_web_data.py [--db PATH] [--out PATH]

Run after scripts/build_segments.py. Also writes docs/data/holidays.json, the
official NYC DOT alternate-side parking holiday calendar for this year and next,
since browsers can't fetch it from nyc.gov directly (no CORS). Re-run when NYC
publishes the next year's calendar.

Block output format (docs/data/blocks.json):

    {
      "names": ["EAST 9 STREET", ...],               # street-name table
      "rules": [[["MON,THURS","9AM","10:30AM"]], ...],  # unique rule sets
      "faces": [[street, from, to, "N", ruleSet, [lon, lat, dlon, dlat, ...]], ...]
    }

Coordinates are integers in 1e-5 degrees (~1 m), delta-encoded after the first
point, which keeps the city-wide file small enough to load on the web.
"""

import argparse
import datetime
import json
import os
import re
import sqlite3
import urllib.error
import urllib.request

ICS_URL = "https://www.nyc.gov/html/dot/downloads/misc/{year}-alternate-side.ics"


def fetch_holidays():
    """[{"date": "2026-10-03", "name": "Shemini Atzereth"}, ...] for this year and next."""
    year = datetime.date.today().year
    holidays = []
    for y in (year, year + 1):
        req = urllib.request.Request(ICS_URL.format(year=y),
                                     headers={"User-Agent": "Mozilla/5.0 (NYC Parking site build)"})
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                text = r.read().decode("utf-8", "replace")
        except urllib.error.HTTPError:
            continue   # next year's calendar may not be published yet
        text = re.sub(r"\r?\n[ \t]", "", text)   # unfold continuation lines
        for event in text.split("BEGIN:VEVENT")[1:]:
            start = re.search(r"^DTSTART[^:]*:(\d{8})", event, re.M)
            desc = re.search(r"^DESCRIPTION:(.*)$", event, re.M)
            name = re.search(r"suspended for (.*?)(?:\.|$)", desc.group(1).replace("\\,", ","), re.I) if desc else None
            if start and name:
                d = start.group(1)
                holidays.append({"date": f"{d[:4]}-{d[4:6]}-{d[6:]}", "name": name.group(1).strip()})
    return sorted(holidays, key=lambda h: h["date"])


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--db", default="NYCParking/NYCParking/segments.db")
    ap.add_argument("--out", default="docs/data/blocks.json")
    ap.add_argument("--holidays-out", default="docs/data/holidays.json")
    args = ap.parse_args()

    conn = sqlite3.connect(args.db)
    names, name_index = [], {}
    rule_sets, rule_index = [], {}

    def name_id(name):
        if name not in name_index:
            name_index[name] = len(names)
            names.append(name)
        return name_index[name]

    def rules_id(rules_json):
        if rules_json not in rule_index:
            rule_index[rules_json] = len(rule_sets)
            rule_sets.append(json.loads(rules_json))
        return rule_index[rules_json]

    faces = []
    for street, from_st, to_st, side, rules, geom in conn.execute(
            "SELECT street, from_st, to_st, side, rules, geom FROM segments"):
        pts = [tuple(map(float, p.split(","))) for p in (geom or "").split(";") if p]
        if len(pts) < 2:
            continue
        coords, prev = [], None
        for lat, lon in pts:
            q = (round(lon * 1e5), round(lat * 1e5))
            if prev is None:
                coords += q
            else:
                coords += (q[0] - prev[0], q[1] - prev[1])
            prev = q
        faces.append([name_id(street), name_id(from_st or ""), name_id(to_st or ""),
                      side or "", rules_id(rules), coords])

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w") as f:
        json.dump({"names": names, "rules": rule_sets, "faces": faces}, f, separators=(",", ":"))
    print(f"Wrote {args.out}: {len(faces)} faces, {len(names)} names, "
          f"{len(rule_sets)} rule sets, {os.path.getsize(args.out) / 1_048_576:.1f} MB")

    holidays = fetch_holidays()
    if holidays:
        with open(args.holidays_out, "w") as f:
            json.dump(holidays, f, indent=1)
        print(f"Wrote {args.holidays_out}: {len(holidays)} holidays "
              f"({holidays[0]['date']} – {holidays[-1]['date']})")
    else:
        print("Could not fetch the holiday calendar; left holidays.json unchanged")


if __name__ == "__main__":
    main()
