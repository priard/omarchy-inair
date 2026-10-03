# Changelog

All notable changes to this plugin. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [0.4.2] — 2026-10-03

### Fixed

- **The plugin seemed not to install.** The pill stayed hidden until the
  first reading. On a machine without stored coordinates, which is Omarchy's
  default (the weather follows the IP address), that reading never came, and
  the panel that explains what is missing could not be opened. The pill is
  now always on the bar: a dimmed `󰵃 —` until there is a reading.
- Without coordinates the panel now says what to do: type a locker code with
  `/`, or store a location with `omarchy-weather-location --set NAME LAT,LON`.
- A pinned locker now works without any location, including on a cold start
  before its id has been cached. Before, discovery stopped at the missing
  location and never looked the pinned code up.

### Changed

- The README's install section explains the coordinates requirement and both
  ways around it.

## [0.4.1] — 2026-10-03

### Changed

- **Terminal skin has room to breathe.** Rows are taller than a line of text,
  and the frame's walls are drawn as continuous lines instead of a `│` per
  row, so the frame stays closed. The panel is wider, too.
- **PM2.5 in pixel digits.** The headline number is drawn in a 3×5 pixel font
  made of real squares.
- **Street weather in block cells**, matching the pollutant meters instead of
  the smooth sliders from 0.4.0. Temperature is a heat strip coloured cell by
  cell from cold to hot, humidity a filled bar, pressure a block on a dotted
  ruler.

### Added

- **Plain skin animation.** Soft motes drift behind the headline, as many as
  the air is dirty, only while the panel is open.

### Fixed

- **"No reading" on a perfectly good reading.** The readings endpoint spells
  the fourth GIOŚ band `SATISFACTORY`, which the plugin didn't know; the panel
  greyed out and showed "No reading". It is now read as "Sufficient".

## [0.4.0] — 2026-10-03

### Changed

- **Renamed from "InPost Air" to "inAir".** The plugin id is now
  `priard.inair` (was `priard.inpost-air`), the repository is
  `priard/omarchy-inair`, and the helpers are `bin/inair-fetch` and
  `bin/inair-location`. The old name could be read as an official InPost
  product. It isn't one, and the README now says so plainly, explains where
  the data comes from, and links InPost's 2021 announcement of the sensors.
  See the README for how to move over from 0.3.0.
- **Colours are readable on every theme.** Index colours keep their GIOŚ/EEA
  hue but are darkened or lightened just enough to reach a minimum contrast
  ratio (WCAG) against the real bar and panel background. This replaces the
  old luminance nudge, which only handled the two extremes of the scale.
  Secondary text is now blended toward the background with a contrast floor
  instead of `Qt.darker()`, which used to make it *less* readable on dark
  themes.
- The index button shows the scale by name, `PL` or `EU`, instead of a swap
  icon. The skin button shows the skin it switches to.
- Sensors in range are coloured on the GIOŚ scale even when the panel shows
  the EEA index. InPost publishes only a GIOŚ verdict for them, and looking
  that up in the EEA table gave wrong or grey colours.
- The user agent is now `omarchy-inair`.

### Fixed

- **The percentage of the norm was wrong.** InPost's third sensor field is
  already a percentage of the legal norm, but it was read as the norm itself
  and the value was divided by it. A PM2.5 reading of 33.7 µg/m³, which is
  135% of the norm, showed as 25%. The meters, percentages and the air flow
  density now use the reported percentage.
- **Header buttons did nothing, or not reliably.** Switching the index or the
  skin waited for a round trip through `shell.json`. When the host had no
  shell to write through, the click was lost (the log said
  `no shell to persist through`). A change now applies to the panel
  immediately and is persisted alongside. If the config later changes from
  outside, for example with `omarchy bar set`, the config wins again.
- The terminal skin's buttons were hard to hit: the click area was only the
  painted glyph. Each button now has a two-cell hit area, a hover highlight
  and a tooltip, which the terminal skin did not show before.

### Added

- **Keyboard shortcuts** in the panel: `/` or `c` for a locker code, `i` for
  the index, `s` for the skin, `r` to refresh. Listed at the bottom of both
  skins and in the tooltips.
- **Terminal skin: street weather.** Temperature, humidity and pressure get a
  section of their own, each with a slider gauge on a fixed scale
  (−20…40 °C, 0–100%, 970–1050 hPa) and a trend arrow. The temperature gauge
  is coloured from cold blue to hot red.
- **Terminal skin: air flow.** Two rows of particles drift under the title,
  denser the dirtier the air. The animation only runs while the panel is open.
- **Terminal skin: PM2.5 trend.** A sparkline over the readings of the
  current session, with the time span it covers. Memory only; it starts over
  when the locker changes, and a reading taken less than a minute after the
  previous one replaces it rather than adding a sample.
- The refresh button spins while a request is in flight.

## 0.3.0 — 2026-09-13

Last release under the name **InPost Air** (`priard.inpost-air`).

- Bar pill with PM2.5, coloured by the Polish (GIOŚ) or European (EEA) index.
- Panel with every reading the sensor publishes, the locker's weather, and
  the other sensors in range. Click a sensor to pin it; type a code to pin any
  locker in Poland.
- Two skins: `terminal` (a character grid) and `plain`.
- Location from Omarchy's own weather setting; never from an IP lookup.
- All network access through a hardened helper with size caps, deadlines and
  validated arguments. Nothing written outside the plugin's `shell.json`
  entry.

[0.4.2]: https://github.com/priard/omarchy-inair/releases/tag/v0.4.2
[0.4.1]: https://github.com/priard/omarchy-inair/releases/tag/v0.4.1
[0.4.0]: https://github.com/priard/omarchy-inair/releases/tag/v0.4.0
