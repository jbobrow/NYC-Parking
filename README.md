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
- **Meters view** — every metered curb colored by whether it's free, paid or commercial-only right now, with rate and time limit ("$2.50 · 2 HR") on the pills; meters off on Sundays and the holidays DOT suspends them
- **Pay with ParkNYC** — a metered block's sheet shows its limit, hours, rate and six-digit ParkNYC zone, and hands off to ParkNYC with the zone copied
- **Countdown mode** — recolors every block by how soon a car parked there now would have to move, or pay the meter: red 0–1 days, yellow 2–6, green 7+. Counts street cleaning, rush-hour / school / overnight no-standing and no-stopping rules, and meter hours, each skipping the holidays it's suspended on. Metered curbs are drawn in meter blue, with the countdown on their pills ("P · 1 DAY")
- **Curb verdict** — a block's sheet leads with what its rules mean right now, strictest first ("No standing until 7 PM", "Free until tomorrow 8:30 AM · then street cleaning")
- **"Park here" mode** — tap any marker to record where you left your car; drag it along the block to the exact spot
- **Next move date** — banner shows the next day you need to move, skipping holidays
- **Reminders** — notifications the evening before, an hour before and ten minutes before the next cleaning, no-standing rule or meter start
- **Double-parking** — from half an hour before street cleaning on your car's block until it ends, the app offers an alarm to repark a set time before it ends (15 minutes to start; your choice is remembered): an alert when the app is open, a notice when cleaning starts, and a toggle on the car's sheet. On iOS 26 it's an AlarmKit alarm that rings through silent mode and Focus, counting down on the Lock Screen and in the Dynamic Island (the `NYCParkingWidgets` extension); earlier, a notification
- **What's New** — a page shown once to people who update, listing that version's highlights (`WhatsNew.releases`)
- **Driving mode** — a 3D view with the parking rules on each side of you, including meters
- **Holiday calendar** — browse the full NYC ASP holiday list

## Data

Parking restriction data comes from the [NYC Open Data alternate-side parking sign dataset](https://data.cityofnewyork.us/resource/nfid-uabd.json), and meters from [ParkNYC Block Faces](https://data.cityofnewyork.us/d/e7yp-wx55) (hours, limits, rates and zone per metered curb). The app ships with a pre-built SQLite database (`segments.db`), built offline by `scripts/build_segments.py`: each sign, and points along each metered curb, are snapped to their block on the [NYC street centerline](https://data.cityofnewyork.us/resource/inkn-q76z) and grouped by block face, giving every face a curb polyline trimmed back from the intersections. Meter hours shared by many curbs are stored once in a `meter_profiles` table. The dates NYC last updated each dataset are stored too, and shown in the app as "data as of".

Meter holidays come from the same DOT holiday calendar as ASP holidays: each entry says whether meters are in effect.

No-standing and no-stopping signs limited to set hours (rush hour, school days, overnight) are parsed and snapped the same way. "Anytime" signs, bus stops and fire zones mark a stretch of curb whose reach isn't in the data, so they're left to the posted signs. A rule signed only once on a longer block is flagged as covering part of it, shown on the block's sheet but not counted on the map. School days are read as Monday to Friday, since there's no school calendar to narrow them.

## Architecture

| File | Role |
|---|---|
| `ParkingDataService` | Loads every block face from SQLite in the background into a `SegmentIndex` |
| `ParkingDatabase` | Read-only SQLite wrapper for the bundled `segments.db` |
| `ParkingSegment` | One block face: street, cross streets, bearing, rules, curb polyline; `SegmentIndex` grid for spatial queries |
| `ParkingMapView` | `MKMapView` wrapper: vector stripe/dot overlays, rotating pill annotations with overlap culling, tap hit-testing, draggable parked car |
| `ParkingLabel` | SwiftUI pill design, rendered once per unique label into a cached image |
| `MoveCountdown` | Days-until-move per block (holiday-aware) and the countdown color buckets |
| `CurbRules` | Day windows, no-standing / no-stopping rules, and the move-or-pay windows countdowns and reminders run on |
| `Meters` | Meter profiles, free/paid/commercial-only status at a moment, and the ParkNYC hand-off |
| `SignParser` | Parses raw NYC sign descriptions into structured `ParkingRule` objects |
| `ASPHolidayService` | Fetches and caches the NYC ASP holiday calendar |

## Scripts

```bash
python3 scripts/build_segments.py
```

Downloads the sign and centerline datasets (cached in `.data_cache/`), snaps signs to block faces, and writes `NYCParking/NYCParking/segments.db`. Rebuild the app afterwards to bundle the new data.

```bash
python3 scripts/build_web_data.py
```

Exports the same block faces to `docs/data/blocks.json` for the website's live map.

## Website

`docs/` is the GitHub Pages site at [nycparking.jonbobrow.com](https://nycparking.jonbobrow.com): a live, simplified version of the app's cleaning-days map (MapLibre GL on OpenFreeMap's dark style), plus the privacy and support pages. Preview it locally with:

```bash
python3 -m http.server 8765 --directory docs
```

## Requirements

- iOS 17+
- Xcode 15+
- Python 3 (standard library only, for the data script)
