#!/usr/bin/env python3
"""
build_web_data.py — Export segments.db to a compact JSON file for the website map.

Usage
-----
    python3 scripts/build_web_data.py [--db PATH] [--out PATH]

Run after scripts/build_segments.py. Also writes docs/data/holidays.json, the
official NYC DOT alternate-side parking holiday calendar for this year and next,
since browsers can't fetch it from nyc.gov directly (no CORS). The app reads
it too, as a fallback when nyc.gov fails. A weekly GitHub Action
(.github/workflows/holidays.yml) runs `--holidays-only` to pick up next year's
calendar once NYC publishes it; if DOT ever moves the file, update ICS_URL
here (or edit holidays.json by hand) and the app follows, no update needed.

Block output format (docs/data/blocks.json):

    {
      "names": ["EAST 9 STREET", ...],               # street-name table
      "rules": [[["MON,THURS","9AM","10:30AM"]], ...],  # unique cleaning rule sets
      "meters": [[paid, commercial, limit_min, first_hour_cents], ...],  # meter profiles
      "restrictions": [[[kind, day_mask, start, end], ...], ...],  # no standing (0) / stopping (1)
      "faces": [[street, from, to, "N", ruleSet, [lon, lat, dlon, dlat, ...], meter, restrictions], ...]
    }

Meter and restriction windows are [day mask (Monday = bit 0), start, end] in
minutes after midnight, as in the app; -1 means none. Only whole-block
restrictions are kept, as the app counts on the map.

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


def fetch_holidays(existing=()):
    """[{"date": "2026-10-03", "name": "Shemini Atzereth", "meters": false}, ...]
    for this year and next. "meters" is whether parking meters are suspended
    too. A year that can't be fetched (next year, until DOT publishes it) keeps
    its entries from `existing`, so a failed fetch never drops a calendar."""
    year = datetime.date.today().year
    by_year = {}
    for h in existing:
        by_year.setdefault(int(h["date"][:4]), []).append(h)
    by_year = {y: hs for y, hs in by_year.items() if y >= year}
    for y in (year, year + 1):
        req = urllib.request.Request(ICS_URL.format(year=y),
                                     headers={"User-Agent": "Mozilla/5.0 (NYC Parking site build)"})
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                text = r.read().decode("utf-8", "replace")
        except (urllib.error.URLError, TimeoutError):
            continue   # next year's calendar may not be published yet
        text = re.sub(r"\r?\n[ \t]", "", text)   # unfold continuation lines
        holidays = []
        for event in text.split("BEGIN:VEVENT")[1:]:
            start = re.search(r"^DTSTART[^:]*:(\d{8})", event, re.M)
            desc = re.search(r"^DESCRIPTION[^:]*:(.*)$", event, re.M)
            desc = desc.group(1).replace("\\,", ",") if desc else ""
            name = re.search(r"suspended for (.*?)(?:\.|$)", desc, re.I)
            if start and name and start.group(1).startswith(str(y)):
                d = start.group(1)
                holiday = {"date": f"{d[:4]}-{d[4:6]}-{d[6:]}", "name": name.group(1).strip()}
                if re.search(r"meters will not be in effect", desc, re.I):
                    holiday["meters"] = True
                elif re.search(r"meters will be in effect", desc, re.I):
                    holiday["meters"] = False
                holidays.append(holiday)
        # DOT lists 30-some days a year; fewer means an error page, not the calendar.
        if len(holidays) >= 10:
            by_year[y] = holidays
        else:
            print(f"{ICS_URL.format(year=y)}: {len(holidays)} holidays, kept the old list")
    return sorted((h for hs in by_year.values() for h in hs), key=lambda h: h["date"])


def write_holidays(path):
    try:
        with open(path) as f:
            existing = json.load(f)
    except (OSError, ValueError):
        existing = []
    holidays = fetch_holidays(existing)
    if holidays and holidays != existing:
        with open(path, "w") as f:
            json.dump(holidays, f, indent=1)
            f.write("\n")
        print(f"Wrote {path}: {len(holidays)} holidays "
              f"({holidays[0]['date']} – {holidays[-1]['date']})")
    else:
        print(f"No new holidays; left {path} unchanged")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--db", default="NYCParking/NYCParking/segments.db")
    ap.add_argument("--out", default="docs/data/blocks.json")
    ap.add_argument("--holidays-out", default="docs/data/holidays.json")
    ap.add_argument("--holidays-only", action="store_true",
                    help="only refresh the holiday calendar (as .github/workflows/holidays.yml does)")
    args = ap.parse_args()

    if args.holidays_only:
        write_holidays(args.holidays_out)
        return

    conn = sqlite3.connect(args.db)
    names, name_index = [], {}
    rule_sets, rule_index = [], {}
    meters, meter_index = [], {}
    restriction_sets, restriction_index = [], {}

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

    profiles = dict(conn.execute("SELECT id, spec FROM meter_profiles"))

    def meter_id(profile):
        """The paid and commercial-only windows, limit and first-hour rate."""
        if profile is None or profile not in profiles:
            return -1
        if profile not in meter_index:
            spec = json.loads(profiles[profile])
            meter_index[profile] = len(meters)
            meters.append([spec.get("windows") or [], spec.get("commercial_windows") or [],
                           spec.get("limit_min") or 0, spec.get("first_hour") or 0])
        return meter_index[profile]

    def restrictions_id(restrictions_json):
        windows = [[0 if kind == "standing" else 1, *w]
                   for kind, ws, _school, part in json.loads(restrictions_json or "[]")
                   if not part for w in ws]
        if not windows:
            return -1
        key = json.dumps(windows)
        if key not in restriction_index:
            restriction_index[key] = len(restriction_sets)
            restriction_sets.append(windows)
        return restriction_index[key]

    faces = []
    for street, from_st, to_st, side, rules, geom, profile, restrictions in conn.execute(
            "SELECT street, from_st, to_st, side, rules, geom, meter_profile, restrictions FROM segments"):
        pts = [tuple(map(float, p.split(","))) for p in (geom or "").split(";") if p]
        meter, restricted = meter_id(profile), restrictions_id(restrictions)
        if len(pts) < 2 or (rules == "[]" and meter < 0 and restricted < 0):
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
                      side or "", rules_id(rules), coords, meter, restricted])

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w") as f:
        json.dump({"names": names, "rules": rule_sets, "meters": meters,
                   "restrictions": restriction_sets, "faces": faces}, f, separators=(",", ":"))
    print(f"Wrote {args.out}: {len(faces)} faces, {len(names)} names, "
          f"{len(rule_sets)} rule sets, {len(meters)} meter profiles, "
          f"{len(restriction_sets)} restriction sets, {os.path.getsize(args.out) / 1_048_576:.1f} MB")

    write_holidays(args.holidays_out)


if __name__ == "__main__":
    main()
