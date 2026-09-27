# NYC Parking

An iOS app that shows alternate-side parking restrictions on a live map, so you can find free street parking in New York City at a glance.

## What it does

NYC alternate-side parking rules are notoriously hard to remember — different days, different times, different sides of the street for every block. This app visualizes all of it on the map so you never have to guess.

**Color-coded markers** appear on every block face that has a no-parking restriction. Each color represents a day of the week. Zoom in to see the full schedule; zoom out to see the whole neighborhood as a dot-per-block overview.

**Mark your car** by tapping a block. The app tracks which block you parked on, shows the next date you need to move, and can set a reminder for 8 AM that morning.

**Holiday awareness** — the app knows NYC's alternate-side parking holiday calendar. If the next restriction day falls on a holiday, it automatically finds the next real enforcement day.

## Features

- **Live map overlay** — parking restriction markers on every block, updated from NYC Open Data
- **Zoom levels**
  - Far out: a run of day-colored dots on each block face
  - Mid: day-colored stripes down each curb, with day-name pills (Mon, Tue, Wed…) lying along the street
  - Close in: pills + restriction time (e.g. 8 AM–11 AM)
- **Countdown mode** — the hourglass button recolors every block by how soon a car parked there now would have to move: red 0–1 days, yellow 2–6, green 7+ (ASP holidays skipped)
- **"Park here" mode** — tap any marker to record where you left your car; drag it along the block to the exact spot
- **Next move date** — banner shows the next day you need to move, skipping holidays
- **Reminders** — optional 8 AM notification on the day you need to move
- **Driving mode** — course-up navigation with a live heading arrow
- **Holiday calendar** — browse the full NYC ASP holiday list

## Data

Parking restriction data comes from the [NYC Open Data alternate-side parking sign dataset](https://data.cityofnewyork.us/resource/nfid-uabd.json). The app ships with a pre-built SQLite database (`segments.db`), built offline by `scripts/build_segments.py`: each sign is snapped to its block on the [NYC street centerline](https://data.cityofnewyork.us/resource/inkn-q76z) and grouped by block face, giving every face a curb polyline trimmed back from the intersections.

## Architecture

| File | Role |
|---|---|
| `ParkingDataService` | Loads every block face from SQLite in the background into a `SegmentIndex` |
| `ParkingDatabase` | Read-only SQLite wrapper for the bundled `segments.db` |
| `ParkingSegment` | One block face: street, cross streets, bearing, rules, curb polyline; `SegmentIndex` grid for spatial queries |
| `ParkingMapView` | `MKMapView` wrapper: vector stripe/dot overlays, rotating pill annotations with overlap culling, tap hit-testing, draggable parked car |
| `ParkingLabel` | SwiftUI pill design, rendered once per unique label into a cached image |
| `MoveCountdown` | Days-until-move per block (holiday-aware) and the countdown color buckets |
| `SignParser` | Parses raw NYC sign descriptions into structured `ParkingRule` objects |
| `ASPHolidayService` | Fetches and caches the NYC ASP holiday calendar |

## Scripts

```bash
python3 scripts/build_segments.py
```

Downloads the sign and centerline datasets (cached in `.data_cache/`), snaps signs to block faces, and writes `NYCParking/NYCParking/segments.db`. Rebuild the app afterwards to bundle the new data.

## Requirements

- iOS 17+
- Xcode 15+
- Python 3 (standard library only, for the data script)
