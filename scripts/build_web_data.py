#!/usr/bin/env python3
"""
build_web_data.py — Export segments.db to a compact JSON file for the website map.

Usage
-----
    python3 scripts/build_web_data.py [--db PATH] [--out PATH]

Run after scripts/build_segments.py. Output format (docs/data/blocks.json):

    {
      "names": ["EAST 9 STREET", ...],               # street-name table
      "rules": [[["MON,THURS","9AM","10:30AM"]], ...],  # unique rule sets
      "faces": [[street, from, to, "N", ruleSet, [lon, lat, dlon, dlat, ...]], ...]
    }

Coordinates are integers in 1e-5 degrees (~1 m), delta-encoded after the first
point, which keeps the city-wide file small enough to load on the web.
"""

import argparse
import json
import os
import sqlite3


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--db", default="NYCParking/NYCParking/segments.db")
    ap.add_argument("--out", default="docs/data/blocks.json")
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


if __name__ == "__main__":
    main()
