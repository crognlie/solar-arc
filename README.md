# Solar Arc

Connect IQ watch face for **Forerunner 965** (Venu 3 is in the manifest; needs its own compile). Round 454×454 AMOLED.

Sideload build: [`dist/SolarArc-fr965.prg`](dist/SolarArc-fr965.prg) — Forerunner 965 only.

Design notes and local build steps: [`watchface/garmin/README.md`](watchface/garmin/README.md).

## Sideload on a Forerunner 965

1. Plug the watch in over USB.
2. Copy `dist/SolarArc-fr965.prg` to **Internal Storage → GARMIN → Apps**.
3. Unplug. Hold **DOWN → Watch Face** and pick **Solar Arc**.

If it is already the active face, switch away and back so the new file loads.

## Build

From `watchface/garmin`, with the Connect IQ SDK and a developer key:

```bat
monkeyc -f monkey.jungle -o bin\SolarArc.prg -d fr965 -y %USERPROFILE%\.garmin\developer_key.der
```

Store package (all products in the manifest):

```bat
monkeyc -e -f monkey.jungle -o bin\SolarArc.iq -y %USERPROFILE%\.garmin\developer_key.der
```

The private key is **not** in this repo. Keep `developer_key.der` somewhere durable; Garmin cannot replace it.

## GitHub Actions secret

CI reads **`GARMIN_DEVELOPER_KEY`**: the key file, **base64-encoded**.

1. Open [New repository secret](https://github.com/crognlie/solar-arc/settings/secrets/actions/new).
2. Name: `GARMIN_DEVELOPER_KEY`
3. In PowerShell, copy the encoded key:

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("$env:USERPROFILE\.garmin\developer_key.der")) | Set-Clipboard
```

4. Paste into **Secret**, then **Add secret**.

Do not commit the `.der`, and do not paste it into issues or chat.
