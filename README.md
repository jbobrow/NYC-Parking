# NYC Parking

An iOS app that shows alternate-side parking restrictions on a live map, so you can find free street parking in New York City at a glance.

## What it does

NYC alternate-side parking rules are notoriously hard to remember — different days, different times, different sides of the street for every block. This app visualizes all of it on the map so you never have to guess.

**Color-coded markers** appear on every block face that has a no-parking restriction. Each color represents a day of the week. Zoom in to see the full schedule; zoom out to see the whole neighborhood as a dot-per-block overview.

**Mark your car** by tapping a block. The app tracks which block you parked on, shows the next date you need to move, and can set a reminder for 8 AM that morning.

**Holiday awareness** — the app knows NYC's alternate-side parking holiday calendar. If the next restriction day falls on a holiday, it automatically finds the next real enforcement day.

## Features

- **Live map overlay** — parking restriction markers on every block, updated from NYC Open Data
- **Three zoom levels**
  - Far out: small colored dots, one per block face
  - Mid: day-name pills (Mon, Tue, Wed…) aligned with the street
  - Close in: pills + restriction time (e.g. 8 AM–11 AM)
- **"Park here" mode** — tap any marker to record where you left your car; drag it along the block to the exact spot
- **Next move date** — banner shows the next day you need to move, skipping holidays
- **Reminders** — optional 8 AM notification on the day you need to move
- **Driving mode** — course-up navigation with a live heading arrow
- **Holiday calendar** — browse the full NYC ASP holiday list

## Data

Parking restriction data comes from the [NYC Open Data alternate-side parking sign dataset](https://data.cityofnewyork.us/resource/nfid-uabd.json). The app ships with a pre-built SQLite database (`segments.db`) so data is available immediately on first launch. Bearings and block-center positions are precomputed offline using `scripts/precompute_bearings.py`.

The app checks for dataset updates on launch and refreshes in the background when a newer version is available.

## Architecture

| File | Role |
|---|---|
| `ParkingDataService` | Loads segments from SQLite, provides `@Published` array to SwiftUI |
| `ParkingDatabase` | SQLite wrapper — bbox queries, cache writes |
| `ParkingSegment` | One block face: street, cross streets, bearing, rules, sidewalk coordinate |
| `ParkingLabel` | SwiftUI pill/dot marker, rotated to match street bearing |
| `ParkingDotsOverlay` | `UIView`-based canvas for the zoomed-out dot layer (performance) |
| `SignParser` | Parses raw NYC sign descriptions into structured `ParkingRule` objects |
| `ASPHolidayService` | Fetches and caches the NYC ASP holiday calendar |

## Scripts

```
scripts/precompute_bearings.py  — run once after data refresh
```

Computes street bearings (local PCA of nearby block centroids) and block center positions (midpoint of cross-street centroids) and writes them into `segments.db`. Run this before bundling the database into the app.

```bash
python3 scripts/precompute_bearings.py NYCParking/NYCParking/segments.db
```

## Requirements

- iOS 17+
- Xcode 15+
- Python 3 + `requests` (for the data script only)
