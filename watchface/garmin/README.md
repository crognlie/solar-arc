# Solar Arc — Garmin watch face

Round 454×454 AMOLED. Builds for **Forerunner 965** and **Venu 3**.

## What's on the face

| y | Region | Content |
|---|---|---|
| 58 | Status row | Bluetooth glyph (blue connected, red not) · notification count + envelope (bright when non-zero, dim at zero, capped at 9+) · battery % |
| 107 | Sun / moon | One sun-on-horizon glyph then `6:36 / 19:44` · moon glyph + countdown |
| 207 | Time | 156px, left. DoW / date / temp stacked to its right |
| 308 | Metrics | Heart glyph + HR · BODY · STRESS, threshold-coloured |
| 336 | Rule | Hairline |
| 364 | Training | Training status + recovery time |
| 426 | Step history | Six ticks, one per prior day, shared baseline |
| bezel | Arcs | Solar cycle on top (accent by day, cool by night), step goal on the bottom |

**Moon countdown** counts to the next new or full moon, whichever is sooner — filled disc for full,
ring for new. Within 24 hours *after* either event it counts backwards instead (`-14h`), so a moon
that has just been full reads as such rather than flipping to a 29-day wait. The number never exceeds
about 15 days.

Three render states: **normal**, **Do Not Disturb** (identical layout on a ~2200K warm ramp, threshold
flagging disabled), and **always-on** (time, `SAT AUG 29`, `BODY 70` — regular weight, no arcs, ~8.5%
of pixels lit, group drifts each minute for burn-in prevention).

## Geometry constraints — read before moving anything

These were all learned by shipping the face to a real wrist and finding it wrong.

**Type floor.** Labels are 17px and values 30–46px. An early build used 9–12px labels; they were
unreadable at arm's length on the real panel even though they looked fine in a mockup on a monitor.
Do not shrink them back to fit more in.

**The step arc eats the bottom of the dial.** Its inner edge is at
`227 + sqrt(213² − dx²) − 7/2` for horizontal offset `dx`, so the ceiling *rises* as you move away
from the vertical axis. `Y_TICKS = 426` is derived from the OUTERMOST tick (dx = 47), not from the
centre — a row placed by its centre will be struck through at its ends.

**The time row is width-critical, and the time is maxed out.** Measured on device, `23:59` at 156px is
293px and the stack's widest line (`29 AUG`) ~100px — 399px of the 406px row. Every other row was
scaled up ~20% to match the mockup's visual weight; the time could not be. To make it bigger the date
stack must move off this row, which would allow ~215px.

**Do not copy font sizes from the HTML mockup.** Device cap ink is 0.551 x the nominal size; CSS cap
ink is ~0.71 x font-size. The same number renders ~22% smaller on the watch, which is why the first
device builds looked uniformly undersized even when the numbers matched.

**The sun/moon row is bottom-aligned to the solar arc.** The arc sweeps 150 to 30 degrees at r=213, so
both endpoints sit at y = 227 - 213 sin30 = 120.5, and the 7px stroke puts its lowest extent at 124 —
which is `Y_SUN`, the row's baseline. The binding width constraint for that row is the chord at the
top of its text box (y~103, 339px), not at its baseline.

**Baselines and ink, not boxes or ascents.** The date stack aligns to the time by ink: the top line's
cap-top on the digits' cap-top, the bottom line's baseline on their baseline. Two traps here, both hit
in real builds:

* `TEXT_JUSTIFY_VCENTER` centres the *line box*, which drifts with font size.
* `getFontAscent()` is baseline-to-box-top **including internal leading** — much larger than cap
  height, and it scales with size. `getTextDimensions()` returns the same box height, so it is no
  better. Aligning a 30px label to 156px digits by either put the label ~30px too high on device
  (twice, in two different builds).

A device probe settled this. On fr965 / CIQ 5.2 these vector fonts report **ascent + descent ==
height exactly** (156 = 124+32, 30 = 24+6, 36 = 29+7) — there is no internal leading, so the baseline
is exactly `boxTop + getFontAscent()` and needs no estimation.

So the baseline is exactly `boxTop + getFontAscent(font)` — no estimation.

Cap height is the one quantity no API reports. It was measured by pixel-scanning a **1:1 454x454
simulator capture** (not a photo of the simulator — photos introduced ~10% scale error that produced
two wrong calibrations): digits 86px at height 156, `SAT` 17px at 30, `29 AUG` 19px at 36, `62F` 17px
at 32 — all ~0.55 x height. Hence `CAP_PER_HEIGHT = 0.551`.

CIQ 5.2 has no `Dc.getPixel`, so ink cannot be scanned at runtime. Being a ratio of height, this holds
at every font size — nothing needs re-measuring when a size changes, which is what broke every earlier
attempt.

**If alignment ever needs rechecking, ask for a direct simulator capture and scan it.** One 1:1 image
answered in a single round what six photo-based rounds could not.
`drawInkTop()` / `drawInkBaseline()` place text by ink and `capHeight()` returns ink height.

The stack is then placed by **distribution, not correction**: the DoW's ink top goes on the digits'
ink top, the temp's baseline on the digits' baseline, and the leftover slack is split evenly between
the three lines. Overlap is impossible by construction, and if the designed sizes cannot fit the
digits' ink at all, `fitStack()` steps them down first.

Earlier builds guessed fractions of the font *height* and added per-line pixel corrections. Every one
of them worked on the build it was measured against and broke on the next, because the corrections
scaled with whatever font size happened to be in play — at one point pulling the stack into the middle
51px of a 111px ink height so the three lines collided. Do not reintroduce anything that has to be
re-measured when a font size changes. Do not reintroduce
metric-based alignment — `getFontAscent()` and `getTextDimensions()` have both been tried and both
return the font box, not the ink.

**Vector fonts are load-bearing, and on the fr965 build they did not load.** Every size in
`loadFonts()` is requested at runtime via `Graphics.getVectorFont`. If none of the candidate face
names resolve, each call silently falls back to a fixed system bitmap and the entire type scale
collapses: measured on device the time's ink was ~74px where 156px vector text gives ~112px, which
also left the three-line date stack no room for leading.

Two causes, both now fixed:

1. **Wrong face names.** The fr965's real Latin faces, from its `simulator.json` (`fontSet: "ww"`,
   `type: "system_ttf"`), are exactly `RobotoRegular`, `RobotoItalic`, `RobotoCondensedRegular`,
   `RobotoCondensedBold` and `BionicBold`. There is no `RobotoBold`, no `RobotoMedium`, no
   `RobotoCondensedSemibold`, and no spaced form like `"Roboto Condensed Bold"`. Earlier builds had
   those invented names in the candidate arrays.
2. **Arrays fail as a unit.** Passing several names in one `getVectorFont` call means a single unknown
   name fails the *entire* request — it does not fall through to the next. `vec()` now tries one name
   per call.

`mVectorOk` records which path was taken; check it first if a new device looks mis-scaled. When false,
`fitStack()` picks the largest system fonts whose three lines of ink plus gaps fit inside the digits'
ink, so the stack degrades proportionally rather than crammed — a safety net, not the design.

When adding a device, read its `simulator.json` for the real face names rather than guessing.

**No seconds.** At 156px the digits plus the stack fill the row. The date is read far more often.

**Icons are drawn from dc primitives** (`drawBluetooth`, `drawEnvelope`, `drawSun`, `drawMoon`,
`drawHeart`), not shipped bitmaps — a handful of glyphs isn't worth a per-resolution asset pipeline,
and the strokes scale with the layout constants. `drawSun` masks below the horizon with a black
rectangle, so it is only correct on a black background.

## Install

You need the Connect IQ SDK. This is a code project, not a store download — building it once is the
only way to get it on the watch.

**1. Install tooling**

- [Connect IQ SDK Manager](https://developer.garmin.com/connect-iq/sdk/) — install it, then use it to
  download the latest SDK plus the device definitions for *Forerunner 965* and *Venu 3*.
- [VS Code](https://code.visualstudio.com/) and the **Monkey C** extension (Garmin, from the
  marketplace).

**2. Generate a developer key** (one time, ever)

In VS Code: `Ctrl/Cmd+Shift+P` → *Monkey C: Generate a Developer Key*. Save it somewhere permanent —
if you lose it you cannot update an app you already published. The extension wires the path into your
settings automatically.

**3. Open and build**

Open the `garmin/` folder in VS Code. Then:

- **Simulator:** `Ctrl/Cmd+Shift+P` → *Monkey C: Run App*, pick `fr965`. The face appears in the
  Connect IQ simulator. Use its **Settings → Watch Face Settings** to test the color and threshold
  options, and **Simulation → Do Not Disturb / Low Power Mode** to see the two alternate states.
- **Device:** `Ctrl/Cmd+Shift+P` → *Monkey C: Build for Device*, pick `fr965`. You get
  `bin/SolarArc.prg`.

**4. Sideload**

Plug the watch in by USB. It mounts as a drive (`GARMIN`). Copy `SolarArc.prg` into
`GARMIN/APPS/`. Eject, unplug. On the watch: hold **DOWN** → *Watch Face* → scroll to **Solar Arc**.

If the watch mounts via MTP instead of as a mass-storage drive (Windows sometimes does this), use
Garmin Express or Android File Transfer to drop the file into the same folder.

**5. Settings**

On-watch: hold **DOWN** → *Watch Face* → **Solar Arc** → *Settings*. Or in the Garmin Connect phone
app: *Device → Connect IQ Apps → Watch Faces → Solar Arc → Settings* — easier for typing threshold
numbers.

Configurable: accent and data colors, threshold palette (flag-problems-only / traffic-light /
cool-to-warm), always-on on/off, warm-DND on/off, and the four body-battery / stress threshold
numbers.

## Files

```
manifest.xml                     products, permissions, api level
monkey.jungle                    build config
resources/strings/strings.xml    UI strings
resources/settings/              properties.xml (defaults) + settings.xml (menus)
resources/drawables/             launcher icon
source/SolarFaceApp.mc           app entry, settings-changed hook
source/SolarFaceView.mc          all rendering; layout constants at the top
source/Solar.mc                  sunrise/sunset + moon phase math
```

## Notes and known soft spots

**Body battery and stress** read `SensorHistory` first, then fall back to Complications. The first
device build showed `--` for both while the simulator showed real numbers; the cause was
`:period => 1`. A one-minute window returns an empty iterator on real hardware whenever the newest
sample is older than a minute, which is normal for these metrics — they update every few minutes. The
simulator synthesises a fresh sample on every call, so it never reproduced the failure. `newestSample()`
now walks up to 8 samples over a 4-hour window, and `complicationValue()` covers devices where the
history API is empty entirely.

**Training status and recovery time** come from the Complications API, read directly once a minute by
`readComplications()`. An earlier build subscribed to change events only; because those fire on
change, a value already settled at startup never arrived and the field stayed `--` forever. Every
read is guarded by a `has` check and a `try`, so a device that doesn't expose one renders `--`
rather than crashing.

**Step history** comes from `ActivityMonitor.getHistory()`, newest-first, reversed for display, and
cached per calendar day. Each tick is that day's steps over that day's own goal, scaled against the
window's peak so a big day doesn't flatten the rest.

**Sunrise/sunset are computed locally** (USNO almanac algorithm) rather than read from an API, so
they work with no connectivity. They need a position, which comes from the last weather observation;
until the watch has one, the default coordinates in `SolarFaceView.mc` (`mLat` / `mLon`, currently
San Francisco) are used. Edit those two lines to your home city if you want correct arcs on first
run. Above the polar circles the arc goes empty and the times show `--:--`.

**Vector fonts.** Sizes are requested at runtime via `Graphics.getVectorFont`. Both target devices
support it. Every request falls back to a system bitmap font if the face name isn't found, which will
look wrong but won't fail to build — if the numerals look off, check the fallback list in
`loadFonts()` against your SDK's device reference.

**Permissions.** The manifest asks for `SensorHistory` and `ComplicationSubscriber`. If your SDK
version complains about an unknown permission id, remove the offending line and rebuild — the guarded
reads degrade gracefully.

## Porting to Venu 3S (390×390)

Do not just scale. The 9px labels would land at 7.7px, below legible on a 1.1" panel. Also,
**training readiness does not exist on the Venu line** — that slot needs to become HRV status or
intensity minutes.

The work is: add `<iq:product id="venu3s"/>` to the manifest, then edit the geometry constants at the
top of `SolarFaceView.mc` — `CX`, `CY`, `ARC_R`, the eight `Y_*` row centres, the `DY_*` date-block
offsets, `GRID_CX`, `X_TIME_LEFT`, `X_STACK_RIGHT`, `X_INSET_SLOTS` — plus the font sizes in
`loadFonts()`. Icon calls take an explicit pixel height, so scale those arguments too.

Recommendation: keep the icon row and the left-weighted time, shrink the time to ~104px, and drop the
metric grid to two cells (body battery + stress) since readiness doesn't exist on the Venu line.
Everything else — the solar arc, thresholds, icons, DND and AOD logic — is resolution-independent and
ports unchanged.

**Watch the bottom arc.** The step-goal arc's inner edge sits at y ≈ 427 near the centre-bottom on a
454px face. Any row placed below y ≈ 410 will be crossed by it, including glyph descenders and
thousands-separator commas. `Y_STEPS` is 406 for exactly this reason; if you move it, recompute
against `227 + sqrt(ARC_R² − dx²) − ARC_W/2` at the row's widest x.
