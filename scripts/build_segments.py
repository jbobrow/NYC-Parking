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

Sources
-------
  Signs:       https://data.cityofnewyork.us/resource/nfid-uabd  (Parking Regulation Signs)
  Centerline:  https://data.cityofnewyork.us/resource/inkn-q76z  (CSCL)

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
PAGE = 50_000

# CSCL roadway types that can carry curbside parking: 1 = street, 10 = alley.
PARKABLE_RW_TYPES = {"1", "10"}

SNAP_RADIUS_M = 30.0       # max sign → centerline distance
SIMILAR_RADIUS_M = 20.0    # tighter radius when the street name only loosely matches
DEFAULT_WIDTH_FT = 34.0    # typical one-way side street, used when width is missing
PARKING_LANE_M = 2.4       # the stripe is drawn down the middle of the parking lane
CORNER_CLEARANCE_M = 2.0   # extra gap between the stripe end and the cross street's curb


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

def build(signs_raw, cscl_raw):
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

    # Snap signs.
    faces = defaultdict(lambda: {"rules": [], "rule_keys": set(), "names": Counter(),
                                 "n": 0})
    stats = Counter()
    for sg in signs_raw:
        rule = parse_rule(sg.get("sign_description") or "")
        if not rule:
            stats["no_rule"] += 1
            continue
        try:
            x_ft = float(sg.get("sign_x_coord") or 0)
            y_ft = float(sg.get("sign_y_coord") or 0)
        except ValueError:
            x_ft = y_ft = 0
        if not x_ft or not y_ft:
            stats["no_coord"] += 1
            continue
        lat, lon = sp_to_latlon(x_ft, y_ft)
        px, py = to_xy(lat, lon)
        want = name_key(sg.get("on_street"))
        boro = BORO_CODES.get((sg.get("borough") or "").upper())

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
            stats["snapped_named"] += 1
        elif best_similar:
            hit = best_similar
            stats["snapped_similar"] += 1
        else:
            stats["unmatched"] += 1
            continue

        _, pid, side, (dx, dy) = hit
        # Which side of the street: the posted side_of_street. Sign coordinates
        # are geocoded onto the centerline (median ~1 m from it), so their
        # position only decides the side when the label is missing or runs
        # along the street.
        label = SIDE_VECTORS.get((sg.get("side_of_street") or "").strip().upper())
        left_dot = (-dy * label[0] + dx * label[1]) if label else 0.0
        if abs(left_dot) >= 0.15:
            on_left = left_dot > 0
            stats["side_from_label"] += 1
            if (side > 0) != on_left:
                stats["side_label_overrode_position"] += 1
        elif abs(side) > 1e-9:
            on_left = side > 0
            stats["side_from_position"] += 1
        else:
            stats["side_unknown"] += 1
            continue
        bid, rev = seg_block[pid]
        is_left = on_left != rev
        key = (bid, "L" if is_left else "R")
        f = faces[key]
        f["n"] += 1
        f["names"][sg.get("on_street") or ""] += 1
        if rule not in f["rule_keys"]:
            f["rule_keys"].add(rule)
            f["rules"].append(rule)

    for k, v in sorted(stats.items()):
        print(f"  signs {k}: {v}")
    print(f"Block faces with rules: {len(faces)}")

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
            "geom": geom,
        })
    print(f"Block faces written: {len(out)}")
    return out


def write_db(faces, path):
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
            geom TEXT
        );
        CREATE INDEX idx_bbox ON segments(lat, lon);
    """)
    generated_at = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    c.execute("INSERT INTO meta VALUES ('generated_at', ?)", (generated_at,))
    c.execute("INSERT INTO meta VALUES ('schema', '2')")
    for f in faces:
        c.execute("INSERT OR REPLACE INTO segments VALUES (?,?,?,?,?,?,?,?,?,?,?)", (
            f["id"], f["street"], f["from"], f["to"], f["side"],
            f["lat"], f["lon"], f["bearing"], f["half_len"],
            json.dumps(f["rules"], separators=(",", ":")),
            # "lat,lon;lat,lon;…" — compact and trivial to parse in Swift.
            ";".join(f"{la},{lo}" for la, lo in f["geom"]),
        ))
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
    faces = build(signs, cscl)
    write_db(faces, args.out)


if __name__ == "__main__":
    sys.exit(main())
