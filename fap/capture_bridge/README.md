# Capture Bridge (`capture_bridge.fap`)

The device half of "press a button on my phone and capture the remote".

The Flipper's protobuf RPC carries no RF messages, so the phone cannot capture by itself. This
app lives on the Flipper, drives the radio, and answers the phone over the RPC
app-data-exchange channel. Nothing about it is phone-specific: the same protocol works from the
`flipper` CLI, qFlipper's RPC, or the fork's own `FlipperKit.RawRPC`.

## Protocol

One ASCII line per exchange, newline terminated.

| Phone sends | Device answers |
|---|---|
| `ping` | `pong` |
| `status` | `idle`, `capturing`, or the last result line |
| `rx <freq_hz> [ms]` | `started` (defaults: 433920000 Hz, 3000 ms), `busy` if a capture is running |
| `result` | last result, e.g. `ok /ext/subghz/cap_20261117-220145.sub pairs=812` |
| `quit` | `bye`, then the app exits |
| anything else | `err unknown` |

A finished capture is also pushed unprompted as `done <result>`.

`status` and `result` return `err ...` lines verbatim, so the phone can show a real reason
(`err no signal 433920000 pairs=0`, `err radio busy`, `err write failed pairs=N`).

## Capture

* Preset `FuriHalSubGhzPresetOok650Async`, raw level/duration pairs, cap 4096 pairs.
* Written as a Flipper Sub-GHz **RAW** file to `/ext/subghz/cap_YYYYMMDD-HHMMSS.sub`,
  re-transmittable straight from the device's Sub-GHz app.
* Standalone (launched from the Flipper menu): the screen shows status, OK captures 3 s on
  433.92 MHz, Back exits.

Not in v0.1: burst trimming, protocol decoding, IR/NFC/RFID capture, frequency scan.

## Build

```sh
cd fap/capture_bridge
ufbt            # builds dist/capture_bridge.fap
ufbt launch     # installs and runs on a USB-connected Flipper
```

Built and verified against the Momentum mntm-012 SDK, API 87.1 with `ufbt` on macOS + Xcode 27.1.

## Phone side (not wired yet)

`flipperhero`'s `Sources/FlipperKit/RawRPC.swift` already exposes the app-data-exchange plumbing:
start the app with `appStart("Capture Bridge", "RPC")`, send `rx 433920000 3000`, then read the
pushed `done ...` line or poll `result`. The macro-pad screen is what will call it.
