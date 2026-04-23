#!/usr/bin/env python3
"""
precompute_bearings.py — Compute accurate street bearings and write them into
segments.db so the iOS app can use them instantly without any runtime work.

How it works
------------
For each segment we collect all other segments on the SAME street within
RADIUS_M metres, then run principal-component analysis on those centroids
(converted to local east/north metres with proper cos-lat longitude scaling).
The dominant axis is the street bearing.

This is better than a city-wide average because it handles curved streets
(Broadway, Queens Blvd, etc.): each block uses only its local neighbours,
so the bearing is correct for that specific stretch, not the whole-city average.

No external API — all data is already in the database.
Runtime: ~30 seconds for the full NYC dataset.

Usage
-----
    python3 scripts/precompute_bearings.py NYCParking/NYCParking/segments.db

After it finishes, rebuild the app with the updated segments.db.
"""

import sqlite3
import math
import sys
from pathlib import Path

RADIUS_M      = 800   # same-street neighbour radius for bearing PCA
MIN_PEERS     = 2     # min neighbours needed for bearing PCA
CROSS_RADIUS  = 200   # cross-street lookup radius for block-center estimation


# ── Geometry helpers ──────────────────────────────────────────────────────────

def haversine_m(lat1, lon1, lat2, lon2):
    R = 6_371_000.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp = math.radians(lat2 - lat1)
    dl = math.radians(lon2 - lon1)
    a  = math.sin(dp/2)**2 + math.cos(p1) * math.cos(p2) * math.sin(dl/2)**2
    return R * 2 * math.atan2(math.sqrt(a), math.sqrt(1.0 - a))


def pca_bearing(coords):
    """
    coords: list of (lat, lon) — at least 2 entries.
    Returns compass bearing [0, 360) of the principal axis, or None.
    """
    n       = len(coords)
    avg_lat = sum(c[0] for c in coords) / n
    avg_lon = sum(c[1] for c in coords) / n
    cos_lat = math.cos(math.radians(avg_lat))

    sxx = sxy = syy = 0.0
    for lat, lon in coords:
        u    = (lon - avg_lon) * cos_lat * 111_320.0   # easting  (m)
        v    = (lat - avg_lat)            * 111_320.0   # northing (m)
        sxx += u * u
        sxy += u * v
        syy += v * v

    if sxx == 0.0 and syy == 0.0:
        return None   # all centroids at the same point

    deg = 0.5 * math.degrees(math.atan2(2.0 * sxy, sxx - syy))
    return (90.0 - deg + 360.0) % 360.0


# ── Main ──────────────────────────────────────────────────────────────────────

def centroid(coords):
    n = len(coords)
    return sum(c[0] for c in coords) / n, sum(c[1] for c in coords) / n


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    db_path = Path(sys.argv[1]).resolve()
    if not db_path.exists():
        sys.exit(f"File not found: {db_path}")

    print(f"Database : {db_path}")

    conn = sqlite3.connect(str(db_path))
    cur  = conn.cursor()

    cur.execute("SELECT id, street, from_st, to_st, lat, lon FROM segments")
    rows = cur.fetchall()
    print(f"Loaded   : {len(rows)} segments\n")

    # Build per-street list for neighbour lookups.
    by_street: dict[str, list[tuple]] = {}
    for seg_id, street, from_st, to_st, lat, lon in rows:
        by_street.setdefault(street.upper(), []).append((seg_id, lat, lon))

    # ── Pass 1: street bearing via local PCA ──────────────────────────────────
    print("Pass 1: computing street bearings...")
    bearing_updated = 0
    bearing_skipped = 0

    for i, (seg_id, street, from_st, to_st, lat, lon) in enumerate(rows):
        peers = by_street.get(street.upper(), [])
        nearby = [
            (p_lat, p_lon)
            for _, p_lat, p_lon in peers
            if haversine_m(lat, lon, p_lat, p_lon) <= RADIUS_M
        ]
        if len(nearby) < MIN_PEERS:
            bearing_skipped += 1
            continue
        bearing = pca_bearing(nearby)
        if bearing is None:
            bearing_skipped += 1
            continue
        cur.execute("UPDATE segments SET bearing = ? WHERE id = ?", (bearing, seg_id))
        bearing_updated += 1
        if bearing_updated % 1000 == 0:
            conn.commit()
            print(f"  {i+1:6d}/{len(rows)}  ({(i+1)/len(rows)*100:5.1f}%)  "
                  f"bearing_updated={bearing_updated}")

    conn.commit()
    print(f"  Done. bearing_updated={bearing_updated}, skipped={bearing_skipped}\n")

    # ── Pass 2: block center via cross-street centroid midpoint ───────────────
    # For each segment we know its from_st and to_st.  Segments on those cross
    # streets that are nearby approximate the two intersection positions.  The
    # midpoint is the true block center — independent of where the signs happen
    # to be clustered.
    print("Pass 2: computing block centers...")
    center_updated = 0
    center_skipped = 0

    for i, (seg_id, street, from_st, to_st, lat, lon) in enumerate(rows):
        if not from_st or not to_st:
            center_skipped += 1
            continue

        from_peers = [
            (p_lat, p_lon)
            for _, p_lat, p_lon in by_street.get(from_st.upper(), [])
            if haversine_m(lat, lon, p_lat, p_lon) <= CROSS_RADIUS
        ]
        to_peers = [
            (p_lat, p_lon)
            for _, p_lat, p_lon in by_street.get(to_st.upper(), [])
            if haversine_m(lat, lon, p_lat, p_lon) <= CROSS_RADIUS
        ]

        if not from_peers or not to_peers:
            center_skipped += 1
            continue

        from_lat, from_lon = centroid(from_peers)
        to_lat,   to_lon   = centroid(to_peers)

        center_lat = (from_lat + to_lat) / 2
        center_lon = (from_lon + to_lon) / 2

        # Half-block length: half the distance between the two intersection estimates.
        half_len = haversine_m(from_lat, from_lon, to_lat, to_lon) / 2
        half_len = max(half_len, 20.0)  # floor at 20 m

        cur.execute(
            "UPDATE segments SET lat = ?, lon = ?, half_len = ? WHERE id = ?",
            (center_lat, center_lon, half_len, seg_id),
        )
        center_updated += 1

        if center_updated % 1000 == 0:
            conn.commit()
            print(f"  {i+1:6d}/{len(rows)}  ({(i+1)/len(rows)*100:5.1f}%)  "
                  f"center_updated={center_updated}")

    conn.commit()
    conn.close()

    print(f"  Done. center_updated={center_updated}, skipped={center_skipped}\n")
    print(f"Next step: copy {db_path.name} back into the Xcode project bundle and rebuild the app.")


if __name__ == "__main__":
    main()
