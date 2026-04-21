#!/usr/bin/env python3
"""
Generates NYCParking/NYCParking/segments.json for bundling with the iOS app.

Usage:
    python3 generate_segments.py

Requires: requests  (pip install requests)

The output file is a SegmentBundle JSON:
  { "generatedAt": "<ISO8601>", "segments": [ ... ] }

Each segment:
  { "id": "BROADWAY|W 42 ST|W 43 ST|W",
    "street": "BROADWAY", "from": "W 42 ST", "to": "W 43 ST", "side": "W",
    "lat": 40.758, "lon": -73.985,
    "bearing": 29.0, "halfLen": 90.0,
    "rules": [{"days":["MON","THURS"],"startTime":"8AM","endTime":"9AM"}] }
"""

import math, json, re, sys, datetime, sqlite3, requests

# ── State Plane EPSG:2263 → WGS84 ─────────────────────────────────────────────
_a   = 6_378_137.0
_e2  = 0.006_694_379_990_14
_e   = 0.081_819_190_842_62
_mPF = 1_200.0 / 3_937.0        # US survey feet → metres
_fPM = 3_937.0 / 1_200.0
_lon0 = math.radians(-74.0)
_lat0 = math.radians(40.0 + 10/60)
_phi1 = math.radians(40.0 + 40/60)
_phi2 = math.radians(41.0 +  2/60)
_fe   = 300_000.0

def _mf(phi):
    s = math.sin(phi); return math.cos(phi) / math.sqrt(1 - _e2*s*s)
def _tf(phi):
    s = math.sin(phi); es = _e*s
    return math.tan(math.pi/4 - phi/2) / ((1-es)/(1+es))**(_e/2)

_m1,_m2 = _mf(_phi1), _mf(_phi2)
_t1,_t2 = _tf(_phi1), _tf(_phi2)
_n  = math.log(_m1/_m2) / math.log(_t1/_t2)
_F  = _m1 / (_n * _t1**_n)
_r0 = _a * _F * _tf(_lat0)**_n

def sp_to_latlon(x_ft, y_ft):
    xm = x_ft * _mPF - _fe
    ym = _r0 - y_ft * _mPF
    rp = math.copysign(math.sqrt(xm*xm + ym*ym), _n)
    tp = (abs(rp) / (_a*_F))**(1/_n)
    phi = math.pi/2 - 2*math.atan(tp)
    for _ in range(10):
        s = math.sin(phi)
        phi = math.pi/2 - 2*math.atan(tp * ((1-_e*s)/(1+_e*s))**(_e/2))
    lam = math.atan2(xm, ym) / _n + _lon0
    return math.degrees(phi), math.degrees(lam)

# ── Day / rule parsing (mirrors Swift SignParser) ──────────────────────────────
_DAY_TOKENS = [
    ("THURS", "THURS"), ("TUES", "TUES"), ("MON", "MON"),
    ("WED", "WED"), ("FRI", "FRI"), ("SAT", "SAT"), ("SUN", "SUN"),
]
_TIME_RE = re.compile(r'(\d{1,2}(?::\d{2})?(?:AM|PM))-(\d{1,2}(?::\d{2})?(?:AM|PM))')

def parse_rule(desc):
    u = desc.upper()
    if "NO PARKING" not in u:
        return None
    m = _TIME_RE.search(u)
    if not m:
        return None
    start, end = m.group(1), m.group(2)
    days = []
    seen = set()
    for token, day in _DAY_TOKENS:
        if token in u and day not in seen:
            seen.add(day)
            days.append(day)
    if not days:
        return None
    return {"days": days, "startTime": start, "endTime": end}

# ── Street bearing via PCA on State Plane coords ───────────────────────────────
def street_bearing(sp_coords):
    if len(sp_coords) < 2:
        return None
    n = len(sp_coords)
    mx = sum(x for x,_ in sp_coords) / n
    my = sum(y for _,y in sp_coords) / n
    sxx = sxy = syy = 0.0
    for x,y in sp_coords:
        dx,dy = x-mx, y-my
        sxx += dx*dx; sxy += dx*dy; syy += dy*dy
    angle = 0.5 * math.atan2(2*sxy, sxx-syy)
    deg = math.degrees(angle)
    return (90.0 - deg + 360.0) % 360.0

# ── Fetch all pages ────────────────────────────────────────────────────────────
BASE = "https://data.cityofnewyork.us/resource/nfid-uabd.json"
SELECT = "order_number,on_street,from_street,to_street,side_of_street,sign_description,sign_x_coord,sign_y_coord"
PAGE  = 10_000

def fetch_all():
    signs = []
    offset = 0
    while True:
        params = {
            "$where":  "upper(sign_description) LIKE '%NO PARKING%'",
            "$select": SELECT,
            "$limit":  PAGE,
            "$offset": offset,
        }
        r = requests.get(BASE, params=params, timeout=60)
        r.raise_for_status()
        page = r.json()
        print(f"  offset {offset}: {len(page)} signs", flush=True)
        signs.extend(page)
        if len(page) < PAGE:
            break
        offset += PAGE
    return signs

# ── Build segments ─────────────────────────────────────────────────────────────
def build_segments(signs):
    buckets = {}
    for s in signs:
        parts = [s.get("on_street",""), s.get("from_street",""),
                 s.get("to_street",""), s.get("side_of_street","")]
        key = "|".join(p.upper() for p in parts if p)
        if not key:
            continue
        buckets.setdefault(key, []).append(s)

    segments = []
    for key, group in buckets.items():
        # Deduplicated rules
        seen_rules = set()
        rules = []
        for sign in group:
            r = parse_rule(sign.get("sign_description") or "")
            if r:
                rkey = "".join(r["days"]) + r["startTime"] + r["endTime"]
                if rkey not in seen_rules:
                    seen_rules.add(rkey)
                    rules.append(r)
        if not rules:
            continue

        # Average lat/lon from State Plane coords
        sp = []
        for sign in group:
            try:
                x = float(sign["sign_x_coord"])
                y = float(sign["sign_y_coord"])
                if x and y:
                    sp.append((x, y))
            except (KeyError, TypeError, ValueError):
                pass
        if not sp:
            continue

        lats, lons = zip(*(sp_to_latlon(x,y) for x,y in sp))
        lat = sum(lats)/len(lats)
        lon = sum(lons)/len(lons)

        bearing = street_bearing(sp)

        # Half-block length
        br = math.radians(bearing or 0)
        mx = sum(x for x,_ in sp)/len(sp)
        my = sum(y for _,y in sp)/len(sp)
        projs = [abs((x-mx)*math.sin(br) + (y-my)*math.cos(br)) for x,y in sp]
        half_len_ft = max(projs) if projs else 0
        half_len_m  = max(half_len_ft * 0.3048006, 20.0)

        ref = group[0]
        segments.append({
            "id":      key,
            "street":  (ref.get("on_street") or "").upper(),
            "from":    (ref.get("from_street") or "").upper(),
            "to":      (ref.get("to_street") or "").upper(),
            "side":    (ref.get("side_of_street") or "").upper(),
            "lat":     round(lat, 6),
            "lon":     round(lon, 6),
            "bearing": round(bearing, 2) if bearing is not None else None,
            "halfLen": round(half_len_m, 1),
            "rules":   rules,
        })

    return segments

# ── Main ───────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    out = "NYCParking/NYCParking/segments.db"

    print("Fetching signs from NYC Open Data…")
    signs = fetch_all()
    print(f"Total signs: {len(signs)}")

    print("Building segments…")
    segs = build_segments(signs)
    print(f"Total segments: {len(segs)}")

    import os
    try:
        os.remove(out)
    except FileNotFoundError:
        pass

    conn = sqlite3.connect(out)
    c = conn.cursor()
    c.executescript("""
        CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE segments (
            id TEXT PRIMARY KEY,
            street TEXT, from_st TEXT, to_st TEXT, side TEXT,
            lat REAL NOT NULL, lon REAL NOT NULL,
            bearing REAL,
            half_len REAL NOT NULL,
            rules TEXT NOT NULL
        );
        CREATE INDEX idx_bbox ON segments(lat, lon);
    """)

    generated_at = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
    c.execute("INSERT INTO meta VALUES (?,?)", ("generated_at", generated_at))

    for seg in segs:
        # Encode rules as compact JSON array: [["MON,THURS","8AM","9AM"], ...]
        rules_arr = [
            [",".join(r["days"]), r["startTime"], r["endTime"]]
            for r in seg["rules"]
        ]
        rules_json = json.dumps(rules_arr, separators=(",", ":"))
        c.execute(
            "INSERT OR REPLACE INTO segments VALUES (?,?,?,?,?,?,?,?,?,?)",
            (
                seg["id"],
                seg["street"],
                seg["from"],
                seg["to"],
                seg["side"],
                seg["lat"],
                seg["lon"],
                seg["bearing"],
                seg["halfLen"],
                rules_json,
            ),
        )

    conn.commit()
    conn.close()

    size_mb = os.path.getsize(out) / 1_048_576
    print(f"Written to {out}  ({size_mb:.1f} MB)")
    print("Add segments.db to the Xcode project as a bundle resource, then build.")
