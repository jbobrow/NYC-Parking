#!/usr/bin/env python3
"""
build_segments.py — Build NYCParking/NYCParking/segments.db from NYC Open Data.

Each row in the output is one *block face*: one side of one street between two
intersections, with the curb line as a polyline and the parking rules posted on
that side.

Why the street centerline is needed
-----------------------------------
A parking-sign "order" often spans several blocks (e.g. E 20 St from 1 Av to
Av C), so grouping signs by order gives one centroid for a multi-block stretch,
which is why the old markers landed mid-block, in parks, or at intersections.
Instead, every sign is snapped to the nearest NYC street-centerline segment
(CSCL, which is split at intersections) with a matching street name, and signs
are grouped by (centerline segment, side of centerline). The curb polyline is the
centerline offset by half the street width, trimmed back from each intersection
by half the cross street's width.

Metered curbs (from the ParkNYC block-face dataset) and time-limited
no-standing / no-stopping signs (rush hour, school days, overnight) are snapped
to the same (centerline block, side) keys, so a face can carry any mix of
cleaning rules, a meter and restrictions.

Sources
-------
  Signs:       https://data.cityofnewyork.us/resource/nfid-uabd  (Parking Regulation Signs)
  Centerline:  https://data.cityofnewyork.us/resource/inkn-q76z  (CSCL)
  Meters:      https://data.cityofnewyork.us/resource/e7yp-wx55  (ParkNYC Block Faces)

Usage
-----
    python3 scripts/build_segments.py [--cache DIR] [--out PATH]

Raw downloads are cached in --cache (default: ./.data_cache) so re-runs are fast;
delete the directory to force a fresh download. No third-party packages needed.
"""

import argparse
import datetime
import difflib
import json
import math
import os
import re
import sqlite3
import sys
import urllib.parse
import urllib.request
from collections import Counter, defaultdict

SIGNS_URL = "https://data.cityofnewyork.us/resource/nfid-uabd.json"
CSCL_URL = "https://data.cityofnewyork.us/resource/inkn-q76z.json"
METERS_URL = "https://data.cityofnewyork.us/resource/e7yp-wx55.json"
DATASET_META_URL = "https://data.cityofnewyork.us/api/views/{id}.json"
PAGE = 50_000

# CSCL roadway types that can carry curbside parking: 1 = street, 10 = alley.
PARKABLE_RW_TYPES = {"1", "10"}

SNAP_RADIUS_M = 30.0       # max sign → centerline distance
SIMILAR_RADIUS_M = 20.0    # tighter radius when the street name only loosely matches
DEFAULT_WIDTH_FT = 34.0    # typical one-way side street, used when width is missing
PARKING_LANE_M = 2.4       # the stripe is drawn down the middle of the parking lane
CORNER_CLEARANCE_M = 2.0   # extra gap between the stripe end and the cross street's curb
METER_SAMPLE_M = 15.0      # spacing of the points snapped along a metered curb
PARTIAL_BLOCK_M = 40.0     # a no-standing rule signed once on a longer block covers part of it


# ── Download ──────────────────────────────────────────────────────────────────

def fetch_paged(url, params, cache_path):
    if os.path.exists(cache_path):
        with open(cache_path) as f:
            return json.load(f)
    rows, offset = [], 0
    while True:
        q = dict(params, **{"$limit": PAGE, "$offset": offset, "$order": ":id"})
        full = url + "?" + urllib.parse.urlencode(q)
        with urllib.request.urlopen(full, timeout=300) as r:
            page = json.load(r)
        rows.extend(page)
        print(f"  {os.path.basename(cache_path)}: {len(rows)} rows", flush=True)
        if len(page) < PAGE:
            break
        offset += PAGE
    with open(cache_path, "w") as f:
        json.dump(rows, f)
    return rows


def fetch_signs(cache_dir):
    return fetch_paged(SIGNS_URL, {
        "$where": "upper(sign_description) LIKE '%NO PARKING%'",
        "$select": "order_number,borough,on_street,from_street,to_street,side_of_street,"
                   "sign_description,sign_x_coord,sign_y_coord",
    }, os.path.join(cache_dir, "signs.json"))


def fetch_centerline(cache_dir):
    return fetch_paged(CSCL_URL, {
        "$select": "physicalid,full_street_name,stname_label,boroughcode,streetwidth,"
                   "number_park_lanes,rw_type,the_geom",
    }, os.path.join(cache_dir, "centerline.json"))


def fetch_standing_signs(cache_dir):
    return fetch_paged(SIGNS_URL, {
        "$where": "upper(sign_description) LIKE '%NO STANDING%' OR upper(sign_description) LIKE '%NO STOPPING%'",
        "$select": "order_number,borough,on_street,from_street,to_street,side_of_street,"
                   "sign_description,sign_x_coord,sign_y_coord,distance_from_intersection,sign_code",
    }, os.path.join(cache_dir, "standing.json"))


def fetch_meters(cache_dir):
    return fetch_paged(METERS_URL, {}, os.path.join(cache_dir, "meters.json"))


def fetch_updated_dates(cache_dir):
    """When NYC last updated each source, shown in the app as "data as of"."""
    path = os.path.join(cache_dir, "updated.json")
    if os.path.exists(path):
        with open(path) as f:
            return json.load(f)
    dates = {}
    for key, dataset in (("signs_updated", "nfid-uabd"), ("meters_updated", "e7yp-wx55")):
        with urllib.request.urlopen(DATASET_META_URL.format(id=dataset), timeout=60) as r:
            ts = json.load(r).get("rowsUpdatedAt")
        if ts:
            dates[key] = datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).strftime("%Y-%m-%d")
    with open(path, "w") as f:
        json.dump(dates, f)
    return dates


# ── State Plane (EPSG:2263, US ft) → WGS84 ────────────────────────────────────

_a, _e2 = 6_378_137.0, 0.006_694_379_990_14
_e = math.sqrt(_e2)
_mPF = 1_200.0 / 3_937.0
_lon0 = math.radians(-74.0)
_lat0 = math.radians(40.0 + 10 / 60)
_phi1 = math.radians(40.0 + 40 / 60)
_phi2 = math.radians(41.0 + 2 / 60)
_fe = 300_000.0


def _mf(phi):
    s = math.sin(phi)
    return math.cos(phi) / math.sqrt(1 - _e2 * s * s)


def _tf(phi):
    s = math.sin(phi)
    es = _e * s
    return math.tan(math.pi / 4 - phi / 2) / ((1 - es) / (1 + es)) ** (_e / 2)


_n = math.log(_mf(_phi1) / _mf(_phi2)) / math.log(_tf(_phi1) / _tf(_phi2))
_F = _mf(_phi1) / (_n * _tf(_phi1) ** _n)
_r0 = _a * _F * _tf(_lat0) ** _n


def sp_to_latlon(x_ft, y_ft):
    xm = x_ft * _mPF - _fe
    ym = _r0 - y_ft * _mPF
    rp = math.copysign(math.hypot(xm, ym), _n)
    tp = (abs(rp) / (_a * _F)) ** (1 / _n)
    phi = math.pi / 2 - 2 * math.atan(tp)
    for _ in range(10):
        s = math.sin(phi)
        phi = math.pi / 2 - 2 * math.atan(tp * ((1 - _e * s) / (1 + _e * s)) ** (_e / 2))
    lam = math.atan2(xm, ym) / _n + _lon0
    return math.degrees(phi), math.degrees(lam)


# ── Local planar projection (metres) ──────────────────────────────────────────
# NYC spans < 50 km, so an equirectangular projection about 40.7°N is accurate
# to well under a metre for the distances we measure.

REF_LAT = 40.7
M_PER_DEG_LAT = 111_320.0
M_PER_DEG_LON = M_PER_DEG_LAT * math.cos(math.radians(REF_LAT))


def to_xy(lat, lon):
    return lon * M_PER_DEG_LON, lat * M_PER_DEG_LAT


def to_latlon(x, y):
    return y / M_PER_DEG_LAT, x / M_PER_DEG_LON


# ── Rule parsing (mirrors Swift SignParser) ───────────────────────────────────

_DAY_TOKENS = [("THURS", "THURS"), ("TUES", "TUES"), ("MON", "MON"),
               ("WED", "WED"), ("FRI", "FRI"), ("SAT", "SAT"), ("SUN", "SUN")]
_TIME_RE = re.compile(r'(\d{1,2}(?::\d{2})?(?:AM|PM))-(\d{1,2}(?::\d{2})?(?:AM|PM))')
_ALL_DAYS = ["MON", "TUES", "WED", "THURS", "FRI", "SAT", "SUN"]
_DAY_ORDER = {d: i for i, d in enumerate(_ALL_DAYS)}


def _match_days(text):
    days, seen = [], set()
    for token, day in _DAY_TOKENS:
        if token in text and day not in seen:
            seen.add(day)
            days.append(day)
    return days


def _extract_days(u):
    """Days a restriction is in effect, honoring "EXCEPT" language.

    Days after "EXCEPT" are exempt; with no explicit day list before it, the
    restriction covers all seven days minus the exempt ones.
    """
    idx = u.find("EXCEPT")
    if idx != -1:
        exempt = set(_match_days(u[idx + len("EXCEPT"):]))
        explicit = _match_days(u[:idx])
        base = explicit if explicit else list(_ALL_DAYS)
        days = [d for d in base if d not in exempt]
    else:
        days = _match_days(u)
    return sorted(days, key=lambda d: _DAY_ORDER[d])


def parse_rule(desc):
    u = desc.upper()
    if "NO PARKING" not in u:
        return None
    m = _TIME_RE.search(u)
    if not m:
        return None
    days = _extract_days(u)
    if not days:
        return None
    return (",".join(days), m.group(1), m.group(2))


# ── No standing / no stopping (read by Swift CurbRestriction) ────────────────

_SIGN_TOKEN_RE = re.compile(
    r"(?P<time>(\d{1,2}(?::\d\d)?)\s*(AM|PM)?\s*-\s*(\d{1,2}(?::\d\d)?)\s*(AM|PM)"
    r"|(MIDNIGHT|NOON|\d{1,2}(?::\d\d)?\s*(?:AM|PM))\s*-\s*(MIDNIGHT|NOON|\d{1,2}(?::\d\d)?\s*(?:AM|PM)))"
    r"|\b(?:(?P<d0>MON)(?:DAY)?|(?P<d1>TUE)(?:S|SDAY)?|(?P<d2>WED)(?:NESDAY)?|(?P<d3>THU)(?:RS|RSDAY)?"
    r"|(?P<d4>FRI)(?:DAY)?|(?P<d5>SAT)(?:URDAY)?|(?P<d6>SUN)(?:DAY)?)\b"
    r"|(?P<range>-|\bTHRU\b|\bTHROUGH\b)")
_DAY_WORDS = r"(?:MON|TUE|WED|THU|FRI|SAT|SUN)[A-Z]*"
# "EXCEPT SUNDAY", "EXCEPT SAT & SUN": only days right after EXCEPT are exempt
# ("EXCEPT TRUCKS LOADING … MON-FRI" exempts trucks, not weekdays).
_EXCEPT_DAYS_RE = re.compile(r"\bEXCEPT\s+(" + _DAY_WORDS + r"(?:\s*(?:&|,|AND|-|THRU)\s*" + _DAY_WORDS + r")*)")


def _sign_clock(t):
    t = t.replace(" ", "")
    if t == "MIDNIGHT":
        return 0
    if t == "NOON":
        return 12 * 60
    m = re.match(r"(\d{1,2})(?::(\d\d))?(AM|PM)", t)
    return _clock(m.group(1), m.group(2), m.group(3))


def _sign_range(m):
    """(start, end) minutes for a time-range token. "7-10AM" takes the end's
    half of the day for the start, unless that would put it after the end."""
    if m.group(6):
        return _sign_clock(m.group(6)), _sign_clock(m.group(7))
    end = _sign_clock(m.group(4) + m.group(5))
    if m.group(3):
        return _sign_clock(m.group(2) + m.group(3)), end
    start = _sign_clock(m.group(2) + m.group(5))
    if start >= end:
        start = _sign_clock(m.group(2) + ("AM" if m.group(5) == "PM" else "PM"))
    return start, end


def _day_bits(start, end):
    """Bits for one day, or the range start…end."""
    if start is None:
        return 1 << end
    return sum(1 << i for i in range(start, end + 1))


def _sign_days(text):
    mask, prev, dash = 0, None, False
    for m in _SIGN_TOKEN_RE.finditer(text):
        if m.group("range"):
            dash = prev is not None
        elif not m.group("time"):
            d = next(i for i in range(7) if m.group(f"d{i}"))
            mask |= _day_bits(prev if dash else None, d)
            prev, dash = d, False
    return mask


def parse_standing(desc):
    """A time-limited no-standing or no-stopping sign, as
    ("standing" | "stopping", [[day mask, start, end], ...], school days?).

    None for anything that isn't limited to set hours. "Anytime" signs, bus
    stops and fire zones mark a stretch of curb (often by a corner or hydrant)
    rather than the block, and their reach isn't in the data, so they're left
    to the posted signs. "School days" are read as Monday to Friday; there's no
    school calendar to narrow them, so they err toward the rule applying, as do
    seasonal signs ("MAY-SEPTEMBER"), which are read as year-round.
    """
    u = desc.upper().replace("–", "-")
    if "NO STOPPING" in u:
        kind = "stopping"
    elif "NO STANDING" in u:
        kind = "standing"
    else:
        return None
    if "ANYTIME" in u or ("BUS" in u and "STOP" in u) or "OTHER TIMES" in u:
        return None
    u = re.sub(r"\([^)]*\)", " ", u)            # "(SUPERSEDES SP-1120B)", "(SYMBOLS)"
    u = re.sub(r"<?-{2,}>?|<-+|->", " ", u)     # arrows
    school = "SCHOOL DAYS" in u

    exempt = 0
    for m in _EXCEPT_DAYS_RE.finditer(u):
        exempt |= _sign_days(m.group(1))
    u = _EXCEPT_DAYS_RE.sub(" ", u)

    # Days apply to the times that follow them ("MONDAY-FRIDAY 7AM-10PM SUNDAY
    # 7AM-5PM"), or to the times before them when named last ("7-10AM MON THRU
    # FRI").
    groups = []          # [day mask, [(start, end), ...]]
    days, prev, dash, trailing = 0, None, False, False
    for m in _SIGN_TOKEN_RE.finditer(u):
        if m.group("time"):
            if days or not groups or trailing:
                groups.append([days, []])
            groups[-1][1].append(_sign_range(m))
            days, prev, dash, trailing = 0, None, False, False
        elif m.group("range"):
            dash = prev is not None
        else:
            d = next(i for i in range(7) if m.group(f"d{i}"))
            bits = _day_bits(prev if dash else None, d)
            if groups and not groups[-1][0] and not days:
                groups[-1][0] |= bits        # days named after their times
                trailing = True
            elif trailing:
                groups[-1][0] |= bits
            else:
                days |= bits
            prev, dash = d, False
    if not groups:
        return None
    default = 0x1F if school else 0x7F
    windows = []
    for mask, times in groups:
        mask = (mask or default) & ~exempt
        for start, end in times:
            if end <= start:
                end += 24 * 60      # overnight: "10PM-5AM"
            if mask:
                windows.append([mask, start, end])
    return (kind, windows, school) if windows else None


# ── Meter parsing (read by Swift MeterInfo) ───────────────────────────────────

_WEEKDAYS = ["MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY", "SATURDAY", "SUNDAY"]
# Time ranges before days, so a range's own dash isn't read as a day range.
_METER_TOKEN_RE = re.compile(
    r"(?P<time>(\d{1,2})(?::(\d\d))?\s*(AM|PM)\s*-\s*(\d{1,2})(?::(\d\d))?\s*(AM|PM))"
    r"|(?P<day>MONDAY|TUESDAY|WEDNESDAY|THURSDAY|FRIDAY|SATURDAY|SUNDAY)(?:DAY)?"
    r"|(?P<dash>-)")
_VEHICLES = {"All Vehicles": "all", "Dual (Commercial / All Vehicles)": "dual",
             "Commercial Only": "commercial"}


def _clock(h, m, ampm):
    return (int(h) % 12 + (12 if ampm == "PM" else 0)) * 60 + int(m or 0)


def parse_meter_hours(text):
    """"Monday-Friday 8:30 AM-12 PM, 2 PM-7 PM, Saturday 8 AM-7 PM" →
    [[day mask, start, end], ...] with Monday as bit 0 and minutes after
    midnight; an end at or before the start runs past midnight.

    A time range applies to the days most recently named. Seasonal variants
    ("… Jan-May, … June-Aug") keep every window, so the union errs toward
    meters being on.
    """
    windows, days, prev_day, dash, after_time = [], 0, None, False, False
    for m in _METER_TOKEN_RE.finditer((text or "").upper()):
        if m.group("time"):
            g = m.groups()
            start, end = _clock(g[1], g[2], g[3]), _clock(g[4], g[5], g[6])
            if end <= start:
                end += 24 * 60
            windows.append([days or 0x7F, start, end])
            after_time, dash = True, False
        elif m.group("day"):
            d = _WEEKDAYS.index(m.group("day"))
            if after_time:
                days, after_time = 0, False
            if dash and prev_day is not None:
                for i in range(prev_day, d + 1):
                    days |= 1 << i
            else:
                days |= 1 << d
            prev_day, dash = d, False
        else:
            dash = prev_day is not None and not after_time
    return windows


def _first_hour_cents(rate):
    m = re.search(r"\$(\d+(?:\.\d\d)?) (?:1st Hour|per Hour|per 30 Minutes)", rate or "")
    if not m:
        return None
    cents = round(float(m.group(1)) * 100)
    return cents * 2 if "per 30 Minutes" in m.group(0) else cents


def _limit_minutes(limit):
    m = re.search(r"(\d+) (Hour|Minute)", limit or "")
    return int(m.group(1)) * (60 if m.group(2) == "Hour" else 1) if m else None


def _na(value):
    value = (value or "").strip()
    return None if value in ("", "N/A") else value


def parse_meter(row):
    """Compact meter record for one ParkNYC block face, or None if unusable."""
    vehicles = _VEHICLES.get((row.get("vehicle_ty") or "").strip())
    zone = (row.get("pay_by_cel") or "").strip()
    if not vehicles or not zone:
        return None
    meter = {"zone": zone, "vehicles": vehicles}
    for prefix, fields in (("", ("all_vehicl", "all_vehi_1", "all_vehi_2")),
                           ("commercial_", ("commercial", "commerci_1", "commerci_2"))):
        limit, hours, rate = (_na(row.get(f)) for f in fields)
        windows = parse_meter_hours(hours)
        if not windows:
            continue
        meter[prefix + "windows"] = windows
        meter[prefix + "hours"] = hours
        if limit:
            meter[prefix + "limit"] = limit
            meter[prefix + "limit_min"] = _limit_minutes(limit)
        if rate:
            meter[prefix + "rate"] = rate
            meter[prefix + "first_hour"] = _first_hour_cents(rate)
    if "windows" not in meter and "commercial_windows" not in meter:
        return None
    return {k: v for k, v in meter.items() if v is not None}


# ── Street-name normalisation ─────────────────────────────────────────────────

_WORDS = {
    "EAST": "E", "WEST": "W", "NORTH": "N", "SOUTH": "S",
    "STREET": "ST", "STR": "ST", "AVENUE": "AV", "AVE": "AV", "PLACE": "PL",
    "ROAD": "RD", "BOULEVARD": "BLVD", "DRIVE": "DR", "LANE": "LN",
    "PARKWAY": "PKWY", "SQUARE": "SQ", "TERRACE": "TER", "COURT": "CT",
    "EXPRESSWAY": "EXPWY", "EXPY": "EXPWY", "HIGHWAY": "HWY", "TURNPIKE": "TPKE",
    "CRESCENT": "CRES", "CIRCLE": "CIR", "PLAZA": "PLZ", "SAINT": "ST",
    "FORT": "FT", "MOUNT": "MT", "CONCOURSE": "CONC", "HEIGHTS": "HTS",
    "EXTENSION": "EXT", "WALK": "WK", "LOOP": "LOOP", "ALLEY": "ALY",
    "SLIP": "SLIP", "ROW": "ROW", "GARDENS": "GDNS", "POINT": "PT",
    "BEACH": "BCH", "VILLAGE": "VLG", "HILL": "HL", "SOUTHWEST": "SW",
    "SOUTHEAST": "SE", "NORTHWEST": "NW", "NORTHEAST": "NE",
    "FIRST": "1", "SECOND": "2", "THIRD": "3", "FOURTH": "4", "FIFTH": "5",
    "SIXTH": "6", "SEVENTH": "7", "EIGHTH": "8", "NINTH": "9", "TENTH": "10",
    "ELEVENTH": "11", "TWELFTH": "12",
}
_ORDINAL_RE = re.compile(r"^(\d+)(ST|ND|RD|TH)$")


def norm_name(name):
    if not name:
        return ""
    tokens = []
    for t in re.split(r"[\s\-\.']+", name.upper()):
        if not t:
            continue
        m = _ORDINAL_RE.match(t)
        if m:
            t = m.group(1)
        tokens.append(_WORDS.get(t, t))
    # "B 69 ST" is the sign dataset's shorthand for Beach 69 St (Rockaways).
    if len(tokens) >= 2 and tokens[0] == "B" and tokens[1].isdigit():
        tokens[0] = "BCH"
    return " ".join(tokens)


def name_key(name):
    """Spacing-insensitive key: MAC DOUGAL ST == MACDOUGAL ST, DE KALB == DEKALB."""
    return norm_name(name).replace(" ", "")


def names_similar(a, b):
    """Loose match for spelling variants (KOSCIUSKO/KOSCIUSZKO, FRED/FREDERICK
    DOUGLASS). Only used for a sign with no exact-name candidate nearby."""
    if not a or not b:
        return False
    if a in b or b in a:
        return True
    return difflib.SequenceMatcher(None, a, b).ratio() >= 0.8


SIDE_VECTORS = {"N": (0.0, 1.0), "S": (0.0, -1.0), "E": (1.0, 0.0), "W": (-1.0, 0.0)}

BORO_CODES = {"MANHATTAN": "1", "BRONX": "2", "BROOKLYN": "3", "QUEENS": "4",
              "STATEN ISLAND": "5"}


# ── Geometry helpers ──────────────────────────────────────────────────────────

def project_on_polyline(px, py, pts):
    """(distance, arclength, signed side, (dx, dy)) of point onto polyline.

    side > 0 means the point is to the LEFT of the digitised direction; (dx, dy)
    is the unit direction of the polyline at the projection.
    """
    best = (float("inf"), 0.0, 0.0, (1.0, 0.0))
    run = 0.0
    for (x1, y1), (x2, y2) in zip(pts, pts[1:]):
        dx, dy = x2 - x1, y2 - y1
        seg2 = dx * dx + dy * dy
        seg = math.sqrt(seg2)
        if seg2 == 0:
            continue
        t = max(0.0, min(1.0, ((px - x1) * dx + (py - y1) * dy) / seg2))
        qx, qy = x1 + t * dx, y1 + t * dy
        d = math.hypot(px - qx, py - qy)
        if d < best[0]:
            cross = dx * (py - y1) - dy * (px - x1)
            best = (d, run + t * seg, cross, (dx / seg, dy / seg))
        run += seg
    return best


def polyline_length(pts):
    return sum(math.hypot(x2 - x1, y2 - y1) for (x1, y1), (x2, y2) in zip(pts, pts[1:]))


def offset_polyline(pts, dist):
    """Offset a polyline to the LEFT by dist metres (negative = right), mitred joins."""
    n = len(pts)
    normals = []
    for (x1, y1), (x2, y2) in zip(pts, pts[1:]):
        L = math.hypot(x2 - x1, y2 - y1) or 1.0
        normals.append((-(y2 - y1) / L, (x2 - x1) / L))
    out = []
    for i in range(n):
        if i == 0:
            nx, ny = normals[0]
        elif i == n - 1:
            nx, ny = normals[-1]
        else:
            ax, ay = normals[i - 1]
            bx, by = normals[i]
            mx, my = ax + bx, ay + by
            ml = math.hypot(mx, my)
            if ml < 1e-6:
                nx, ny = bx, by
            else:
                mx, my = mx / ml, my / ml
                cos_half = max(0.3, mx * ax + my * ay)   # clamp mitre on sharp turns
                nx, ny = mx / cos_half, my / cos_half
        out.append((pts[i][0] + nx * dist, pts[i][1] + ny * dist))
    return out


def trim_polyline(pts, start, end):
    """Sub-polyline from arclength `start` to `total - end`."""
    total = polyline_length(pts)
    a, b = start, total - end
    if b - a < 1.0:
        return None
    out, run = [], 0.0
    for (x1, y1), (x2, y2) in zip(pts, pts[1:]):
        seg = math.hypot(x2 - x1, y2 - y1)
        if seg == 0:
            continue
        s0, s1 = run, run + seg
        if s1 >= a and s0 <= b:
            t0 = max(0.0, (a - s0) / seg)
            t1 = min(1.0, (b - s0) / seg)
            p0 = (x1 + (x2 - x1) * t0, y1 + (y2 - y1) * t0)
            p1 = (x1 + (x2 - x1) * t1, y1 + (y2 - y1) * t1)
            if not out:
                out.append(p0)
            out.append(p1)
        run = s1
    return out if len(out) >= 2 else None


def point_and_bearing_at(pts, s):
    run = 0.0
    for (x1, y1), (x2, y2) in zip(pts, pts[1:]):
        seg = math.hypot(x2 - x1, y2 - y1)
        if seg == 0:
            continue
        if run + seg >= s:
            t = (s - run) / seg
            bearing = (math.degrees(math.atan2(x2 - x1, y2 - y1)) + 360) % 360
            return (x1 + (x2 - x1) * t, y1 + (y2 - y1) * t), bearing
        run += seg
    (x1, y1), (x2, y2) = pts[-2], pts[-1]
    return pts[-1], (math.degrees(math.atan2(x2 - x1, y2 - y1)) + 360) % 360


def order_chain(members, segs, node_key):
    """Order same-street pieces end-to-end into one path.

    Returns [(piece id, reversed)] from one end to the other, or None when the
    pieces don't form a simple path (loops, forks), in which case each piece is
    treated as its own block.
    """
    if len(members) == 1:
        return [(members[0], False)]
    at_node = defaultdict(list)
    for pid in members:
        at_node[node_key(segs[pid]["pts"][0])].append(pid)
        at_node[node_key(segs[pid]["pts"][-1])].append(pid)
    ends = [n for n, ps in at_node.items() if len(ps) == 1]
    if len(ends) != 2 or any(len(ps) > 2 for ps in at_node.values()):
        return None
    chain, used, node = [], set(), ends[0]
    while True:
        nxt = [p for p in at_node[node] if p not in used]
        if not nxt:
            break
        pid = nxt[0]
        used.add(pid)
        rev = node_key(segs[pid]["pts"][0]) != node
        chain.append((pid, rev))
        node = node_key(segs[pid]["pts"][0] if rev else segs[pid]["pts"][-1])
    return chain if len(chain) == len(members) else None


def compass_side(nx, ny):
    """Cardinal letter for an outward normal vector (x east, y north)."""
    ang = (math.degrees(math.atan2(nx, ny)) + 360) % 360
    return "NESW"[int(((ang + 45) % 360) // 90)]


# ── Main build ────────────────────────────────────────────────────────────────

def build(signs_raw, cscl_raw, meters_raw, standing_raw):
    # Centerline segments, in metres.
    segs = {}
    for r in cscl_raw:
        if r.get("rw_type") not in PARKABLE_RW_TYPES:
            continue
        geom = r.get("the_geom") or {}
        lines = geom.get("coordinates") or []
        if not lines:
            continue
        # MultiLineStrings are almost always a single part; chain parts in order.
        pts = []
        for line in lines:
            for lon, lat in line:
                p = to_xy(lat, lon)
                if not pts or p != pts[-1]:
                    pts.append(p)
        if len(pts) < 2:
            continue
        pid = r["physicalid"]
        try:
            width_ft = float(r.get("streetwidth") or 0) or DEFAULT_WIDTH_FT
        except ValueError:
            width_ft = DEFAULT_WIDTH_FT
        segs[pid] = {
            "pts": pts,
            "name": name_key(r.get("full_street_name")),
            "label": (r.get("stname_label") or r.get("full_street_name") or "").strip(),
            "boro": r.get("boroughcode"),
            "width_m": width_ft * 0.3048,
        }
    print(f"Centerline segments: {len(segs)}")

    # Grid index of polyline vertices' bounding boxes.
    CELL = 60.0
    grid = defaultdict(list)
    for pid, s in segs.items():
        xs = [p[0] for p in s["pts"]]
        ys = [p[1] for p in s["pts"]]
        for gx in range(int(min(xs) // CELL), int(max(xs) // CELL) + 1):
            for gy in range(int(min(ys) // CELL), int(max(ys) // CELL) + 1):
                grid[(gx, gy)].append(pid)

    # Node → segments, for cross-street names and intersection trimming.
    def node_key(p):
        return (round(p[0], 1), round(p[1], 1))

    node_segs = defaultdict(set)
    for pid, s in segs.items():
        node_segs[node_key(s["pts"][0])].add(pid)
        node_segs[node_key(s["pts"][-1])].add(pid)

    # Merge centerline pieces into whole blocks. CSCL splits a street at every
    # node, including mid-block ones (width changes, driveways, turn bays). Where
    # a node joins exactly two pieces of the same street, both belong to one block.
    parent = {pid: pid for pid in segs}

    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a

    for pids in node_segs.values():
        if len(pids) == 2:
            a, b = pids
            if segs[a]["name"] and segs[a]["name"] == segs[b]["name"]:
                parent[find(a)] = find(b)

    groups = defaultdict(list)
    for pid in segs:
        groups[find(pid)].append(pid)

    blocks = {}      # block id → {"pts", "name", "label", "width_m", "members"}
    seg_block = {}   # piece id → (block id, piece runs against block direction)
    for members in groups.values():
        chain = order_chain(members, segs, node_key)
        if chain is None:
            chain_list = [[(pid, False)] for pid in members]
        else:
            chain_list = [chain]
        for ch in chain_list:
            bid = min(pid for pid, _ in ch)
            pts = []
            wsum = lsum = 0.0
            for pid, rev in ch:
                piece = segs[pid]["pts"][::-1] if rev else segs[pid]["pts"]
                pts.extend(piece if not pts else piece[1:])
                L = polyline_length(segs[pid]["pts"])
                wsum += segs[pid]["width_m"] * L
                lsum += L
                seg_block[pid] = (bid, rev)
            first = segs[ch[0][0]]
            blocks[bid] = {"pts": pts, "name": first["name"], "label": first["label"],
                           "width_m": wsum / lsum if lsum else first["width_m"],
                           "members": {pid for pid, _ in ch}}
    print(f"Blocks after merging mid-block nodes: {len(blocks)}")

    # Display names in the sign dataset's style ("EAST 20 STREET"), keyed by
    # normalised name, so cross streets read the same as the street itself.
    display = defaultdict(Counter)
    for sg in signs_raw:
        for field in ("on_street", "from_street", "to_street"):
            raw = " ".join((sg.get(field) or "").upper().split())
            if raw:
                display[name_key(raw)][raw] += 1

    def display_name(key, fallback):
        c = display.get(key)
        return c.most_common(1)[0][0] if c else " ".join(fallback.upper().split())

    def face_key(px, py, street, borough, side_label, stats, kind):
        """(block id, "L"/"R") of the block face nearest a point, or None."""
        want = name_key(street)
        boro = BORO_CODES.get((borough or "").strip().upper())
        gx, gy = int(px // CELL), int(py // CELL)
        cands = set()
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                cands.update(grid.get((gx + dx, gy + dy), ()))

        best_named, best_similar = None, None
        for pid in cands:
            s = segs[pid]
            if boro is not None and s["boro"] != boro:
                continue
            d, along, side, direction = project_on_polyline(px, py, s["pts"])
            if d > SNAP_RADIUS_M:
                continue
            item = (d, pid, side, direction)
            if want and s["name"] == want:
                if best_named is None or d < best_named[0]:
                    best_named = item
            elif d <= SIMILAR_RADIUS_M and names_similar(want, s["name"]):
                if best_similar is None or d < best_similar[0]:
                    best_similar = item

        if best_named:
            hit = best_named
            stats[f"{kind} snapped_named"] += 1
        elif best_similar:
            hit = best_similar
            stats[f"{kind} snapped_similar"] += 1
        else:
            stats[f"{kind} unmatched"] += 1
            return None

        _, pid, side, (dx, dy) = hit
        # Which side of the street: the posted side_of_street. Sign coordinates
        # are geocoded onto the centerline (median ~1 m from it), so their
        # position only decides the side when the label is missing or runs
        # along the street.
        label = SIDE_VECTORS.get((side_label or "").strip().upper())
        left_dot = (-dy * label[0] + dx * label[1]) if label else 0.0
        if abs(left_dot) >= 0.15:
            on_left = left_dot > 0
            stats[f"{kind} side_from_label"] += 1
            if (side > 0) != on_left:
                stats[f"{kind} side_label_overrode_position"] += 1
        elif abs(side) > 1e-9:
            on_left = side > 0
            stats[f"{kind} side_from_position"] += 1
        else:
            stats[f"{kind} side_unknown"] += 1
            return None
        bid, rev = seg_block[pid]
        return (bid, "L" if on_left != rev else "R")

    # Snap signs.
    faces = defaultdict(lambda: {"rules": [], "rule_keys": set(), "names": Counter(),
                                 "n": 0, "meter": None, "meter_len": 0.0,
                                 "standing": defaultdict(list)})
    stats = Counter()
    for sg in signs_raw:
        rule = parse_rule(sg.get("sign_description") or "")
        if not rule:
            stats["signs no_rule"] += 1
            continue
        try:
            x_ft = float(sg.get("sign_x_coord") or 0)
            y_ft = float(sg.get("sign_y_coord") or 0)
        except ValueError:
            x_ft = y_ft = 0
        if not x_ft or not y_ft:
            stats["signs no_coord"] += 1
            continue
        px, py = to_xy(*sp_to_latlon(x_ft, y_ft))
        key = face_key(px, py, sg.get("on_street"), sg.get("borough"),
                       sg.get("side_of_street"), stats, "signs")
        if not key:
            continue
        f = faces[key]
        f["n"] += 1
        f["names"][sg.get("on_street") or ""] += 1
        if rule not in f["rule_keys"]:
            f["rule_keys"].add(rule)
            f["rules"].append(rule)
    print(f"Block faces with rules: {len(faces)}")

    # Snap time-limited no-standing / no-stopping signs, keeping where along
    # the block each one stands, to judge how much of the block a rule covers.
    for sg in standing_raw:
        parsed = parse_standing(sg.get("sign_description") or "")
        if not parsed:
            stats["standing not_time_limited"] += 1
            continue
        try:
            x_ft = float(sg.get("sign_x_coord") or 0)
            y_ft = float(sg.get("sign_y_coord") or 0)
        except ValueError:
            x_ft = y_ft = 0
        if not x_ft or not y_ft:
            stats["standing no_coord"] += 1
            continue
        px, py = to_xy(*sp_to_latlon(x_ft, y_ft))
        key = face_key(px, py, sg.get("on_street"), sg.get("borough"),
                       sg.get("side_of_street"), stats, "standing")
        if not key:
            continue
        _, along, _, _ = project_on_polyline(px, py, blocks[key[0]]["pts"])
        rule = json.dumps(parsed, separators=(",", ":"))
        faces[key]["standing"][rule].append(along)

    # Snap metered curbs. One ParkNYC face can span several blocks, so sample
    # points along it; each block face that collects enough samples gets the
    # meter. Where two meters land on one face (a block split between zones),
    # the one covering more of it wins.
    for row in meters_raw:
        meter = parse_meter(row)
        lines = (row.get("the_geom") or {}).get("coordinates") or []
        pts = [to_xy(lat, lon) for line in lines for lon, lat in line]
        if not meter or len(pts) < 2:
            stats["meters unusable"] += 1
            continue
        length = polyline_length(pts)
        n = max(1, round(length / METER_SAMPLE_M))
        hits = Counter()
        for i in range(n):
            (px, py), _ = point_and_bearing_at(pts, (i + 0.5) * length / n)
            key = face_key(px, py, row.get("on_street"), row.get("borough"),
                           row.get("side_of_st"), Counter(), "meters")
            if key:
                hits[key] += 1
        # Ignore strays near the ends that fall on the next block.
        keys = [k for k, c in hits.items() if c >= min(2, n) or c == max(hits.values())]
        stats["meters snapped" if keys else "meters unmatched"] += 1
        stats["meter faces"] += len(keys)
        for key in keys:
            f = faces[key]
            covered = hits[key] * length / n
            if f["meter"] is not None:
                stats["meters sharing_a_face"] += 1
            if covered > f["meter_len"]:
                f["meter"], f["meter_len"] = meter, covered

    for k, v in sorted(stats.items()):
        print(f"  {k}: {v}")
    print(f"Block faces with rules or meters: {len(faces)}")

    # Build geometry per face.
    out = []
    for (bid, side), f in faces.items():
        s = blocks[bid]
        pts = s["pts"]
        sign = 1 if side == "L" else -1
        curb_offset = max(2.0, s["width_m"] / 2 - PARKING_LANE_M / 2)
        curb = offset_polyline(pts, sign * curb_offset)

        def trim_at(end_pt):
            others = node_segs.get(node_key(end_pt), set()) - s["members"]
            if not others:
                return 0.0, ""
            widths = [segs[o]["width_m"] for o in others]
            cross = sorted({o for o in others
                            if segs[o]["name"] and segs[o]["name"] != s["name"]
                            and not segs[o]["name"].startswith("UNNAMED")},
                           key=lambda o: -segs[o]["width_m"])
            name = display_name(segs[cross[0]]["name"], segs[cross[0]]["label"]) if cross else ""
            return max(widths) / 2 + CORNER_CLEARANCE_M, name

        trim_a, from_name = trim_at(pts[0])
        trim_b, to_name = trim_at(pts[-1])
        total = polyline_length(curb)
        # Never trim away more than 70% of a short block.
        scale = min(1.0, 0.7 * total / max(trim_a + trim_b, 1e-6))
        curb_t = trim_polyline(curb, trim_a * scale, trim_b * scale)
        if not curb_t:
            continue
        length = polyline_length(curb_t)
        (mx, my), bearing = point_and_bearing_at(curb_t, length / 2)
        mlat, mlon = to_latlon(mx, my)

        # Outward (sidewalk-facing) normal at the midpoint → compass side letter.
        br = math.radians(bearing)
        tx, ty = math.sin(br), math.cos(br)
        nx, ny = (-ty * sign, tx * sign)
        compass = compass_side(nx, ny)

        # Rules sorted by first weekday for stable display.
        rules = sorted(f["rules"], key=lambda r: (_DAY_ORDER[r[0].split(",")[0]], r[1]))
        geom = [[round(la, 6), round(lo, 6)] for la, lo in (to_latlon(x, y) for x, y in curb_t)]

        out.append({
            "id": f"{bid}{side}",
            "street": display_name(s["name"], s["label"]),
            "from": from_name,
            "to": to_name,
            "side": compass,
            "lat": round(mlat, 6),
            "lon": round(mlon, 6),
            "bearing": round(bearing, 2),
            "half_len": round(length / 2, 1),
            "rules": [list(r) for r in rules],
            "meter": f["meter"],
            "restrictions": restrictions(f["standing"], polyline_length(pts)),
            "geom": geom,
        })
    print(f"Block faces written: {len(out)}")
    return out


def restrictions(standing, block_len):
    """[[kind, windows, school days?, part of block?], ...] for a face.

    Each sign applies until the next one, so a rule's signs rarely span its
    whole stretch; but a rule posted only once on a longer block is likely a
    short zone (by a school entrance, say) rather than the block.
    """
    out = []
    for rule, positions in sorted(standing.items()):
        kind, windows, school = json.loads(rule)
        partial = len(positions) == 1 and block_len > PARTIAL_BLOCK_M
        out.append([kind, windows, int(school), int(partial)])
    return out


def write_db(faces, path, updated):
    tmp = path + ".tmp"
    if os.path.exists(tmp):
        os.remove(tmp)
    conn = sqlite3.connect(tmp)
    c = conn.cursor()
    c.executescript("""
        CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE segments (
            id TEXT PRIMARY KEY,
            street TEXT, from_st TEXT, to_st TEXT, side TEXT,
            lat REAL NOT NULL, lon REAL NOT NULL,
            bearing REAL,
            half_len REAL NOT NULL,
            rules TEXT NOT NULL,
            geom TEXT,
            meter_zone TEXT,
            meter_profile INTEGER,
            restrictions TEXT
        );
        CREATE INDEX idx_bbox ON segments(lat, lon);
        -- Meter hours, limits and rates, shared by every curb that has them
        -- (a few hundred distinct profiles across ~12k metered curbs).
        CREATE TABLE meter_profiles (id INTEGER PRIMARY KEY, spec TEXT NOT NULL);
    """)
    generated_at = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    c.execute("INSERT INTO meta VALUES ('generated_at', ?)", (generated_at,))
    c.execute("INSERT INTO meta VALUES ('schema', '4')")
    for key, value in updated.items():
        c.execute("INSERT INTO meta VALUES (?, ?)", (key, value))
    profiles = {}
    for f in faces:
        zone = profile = None
        if f["meter"]:
            spec = dict(f["meter"])
            zone = spec.pop("zone")
            key = json.dumps(spec, separators=(",", ":"), sort_keys=True)
            profile = profiles.setdefault(key, len(profiles))
        c.execute("INSERT OR REPLACE INTO segments VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)", (
            f["id"], f["street"], f["from"], f["to"], f["side"],
            f["lat"], f["lon"], f["bearing"], f["half_len"],
            json.dumps(f["rules"], separators=(",", ":")),
            # "lat,lon;lat,lon;…" — compact and trivial to parse in Swift.
            ";".join(f"{la},{lo}" for la, lo in f["geom"]),
            zone, profile,
            json.dumps(f["restrictions"], separators=(",", ":")) if f["restrictions"] else None,
        ))
    c.executemany("INSERT INTO meter_profiles VALUES (?, ?)",
                  [(i, spec) for spec, i in profiles.items()])
    conn.commit()
    c.execute("VACUUM")
    conn.close()
    os.replace(tmp, path)
    print(f"Wrote {path} ({os.path.getsize(path) / 1_048_576:.1f} MB)")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--cache", default=".data_cache")
    ap.add_argument("--out", default="NYCParking/NYCParking/segments.db")
    args = ap.parse_args()
    os.makedirs(args.cache, exist_ok=True)
    print("Fetching signs…")
    signs = fetch_signs(args.cache)
    print(f"  {len(signs)} signs")
    print("Fetching street centerline…")
    cscl = fetch_centerline(args.cache)
    print(f"  {len(cscl)} centerline segments")
    print("Fetching metered block faces…")
    meters = fetch_meters(args.cache)
    print("Fetching no-standing / no-stopping signs…")
    standing = fetch_standing_signs(args.cache)
    print(f"  {len(standing)} signs")
    print(f"  {len(meters)} metered block faces")
    updated = fetch_updated_dates(args.cache)
    print(f"  source dates: {updated}")
    faces = build(signs, cscl, meters, standing)
    write_db(faces, args.out, updated)


if __name__ == "__main__":
    sys.exit(main())
