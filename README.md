# Gadgetbridge Sleep Widget runner

This repository contains a GitHub Actions workflow that clones Gadgetbridge, adds an experimental Android home-screen sleep/health widget, builds a debug APK, and uploads both the APK and patch as artifacts.

## Widget features

- circular 24-hour sleep-stage ring
- total sleep inside the circle
- Sleep and Woke times inside the circle
- smaller sleep circle and larger Sleep/Woke text from v41
- 4-hour heart-rate line
- highest heart-rate dot and value
- latest heart-rate value on the right side of the graph
- compact semicircle HRV gauge inspired by the Gadgetbridge dashboard
- HRV gauge uses a fixed value-to-angle scale so the same HRV value always lands at the same marker position
- HRV status text removed to avoid overlap and match the requested reference style
- temperature shown as a number only
- temperature turns red above 37.2 °C and blue otherwise
- no gray background cards behind HRV or temperature
- tap the graph to fetch/refresh recorded activity data
- tap the widget root to open Gadgetbridge charts

## Data sources

The widget prefers generated DAO tables used by Colmi/generic dashboard data when available:

- `ColmiSleepStageSample` / `GenericSleepStageSample`
- `ColmiHeartRateSample` / `GenericHeartRateSample`
- `ColmiTemperatureSample` / `GenericTemperatureSample`
- `ColmiHrvValueSample` / `GenericHrvValueSample`
- `ColmiHrvSummarySample`

It still falls back to Gadgetbridge activity samples for devices that expose sleep through normal activity data.

## How to use

1. Push these files to a GitHub repository.
2. Open **Actions**.
3. Run **Build Active Time Widget APK** manually.
4. Download the `gadgetbridge-active-time-widget-apk` artifact.
5. Install the APK on your Android device.
6. Long-press your home screen → **Widgets** → **Gadgetbridge** → **Sleep**.

If you already have Gadgetbridge installed from F-Droid or another source, Android may reject the debug APK because it is signed with a different key. Back up Gadgetbridge first, uninstall the existing app, then install the GitHub-built debug APK.

## Notes

Android launcher widgets use `RemoteViews`, so the in-app chart view cannot be embedded directly. This runner draws the sleep-stage ring, heart-rate chart, HRV gauge, and temperature readout into a `Bitmap` and sets it on an `ImageView` instead.

The workflow retries cloning Gadgetbridge up to five times and then tries the fallback repository if Codeberg returns a temporary HTTP 502/RPC error. You can change the fallback repository in the manual workflow inputs.

## Version notes

- v24: removed SpO₂ from the widget, changed temperature from dots to a line, made the widget taller, separated the circular 24-hour sleep-stage chart from the heart-rate chart, and adjusted Colmi sleep-stage mapping so light sleep should render correctly.
- v28: shifted fixed 30–200 BPM scale labels farther right so they do not overlap the current heart-rate or temperature value labels.
- v30: changed the sleep dial to one 24-hour ring with labels 0, 3, 6, 9, 12, 15, 18, and 21 around the same circle.
- v31: slightly smaller circular 24-hour sleep ring for better spacing.
- v32: total sleep, sleep time, and wake time are rendered inside the circular sleep ring.
- v33: moved sleep/wake text under total sleep inside the dial and lowered the dial slightly so the 0 label is not clipped.
- v34: removed thin chart grid/axis lines and numbers from the lower graph, leaving only heart-rate and temperature lines, plus a dot at the highest heart-rate point.
- v35: restored right-side current heart-rate and temperature value labels while keeping the simplified lower chart.
- v36: the highest heart-rate dot now also shows its value above the dot.
- v37: moved the latest heart-rate and temperature value labels farther inward so they do not get cut off at the right edge.
- v38: moved the heart-rate and temperature plot area left by reserving a dedicated right-side margin for the current value labels.
- v39: shortened the lower heart-rate chart to 4 hours, added a compact HRV gauge and temperature readout on the left, and changed temperature to a standalone colored measurement.
- v40: restyled the HRV gauge to better match the app dashboard reference, with segmented arc colors, a marker dot on the arc, larger value text with ms, and status text below.
- v41: made the circular sleep dial smaller, increased the in-dial Sleep/Woke text size, and removed the gray background cards behind the HRV and temperature sections.
- v42: normalizes generated DAO data before drawing so sleep segments, heart-rate samples, and temperature samples are chronological and duplicate timestamps are compacted. HRV now keeps the newest value across Colmi and Generic DAO sources instead of letting an older table overwrite it. Empty sleep data now shows `Sleep —` instead of a misleading midnight start time.
- v43: fixes the HRV value/status overlap by moving the HRV status into the sparse left edge of the heart-rate chart area and drawing it after the HR line. It also pulls the 24-hour dial labels inward so the bottom `12` label has more clearance from the lower charts.
- v44: restyles HRV as a smaller Gadgetbridge-like semicircle gauge with thick colored arc segments, centered `value ms` text, no `Balanced`/status text, and a fixed HRV scale so the marker is stable for the same value. The HRV gauge is drawn after the heart-rate line so it can safely extend into the sparse chart area without becoming unreadable.
- v45: moves the centered HRV `value ms` text slightly downward inside the semicircle so it no longer touches the gauge arc.
- v46: shifts the 4-hour heart-rate chart slightly to the right while moving the current heart-rate value with it, creating a bit more separation from the HRV gauge.
