# FERMAXO RACING · F1 2026 DISPLAY

A phone-first single-screen telemetry instrument for EA SPORTS F1 25 with the 2026 Season Pack UDP mode.

## Current implementation

This repository started empty. The initial build provides a responsive single-screen display and a local Python bridge. The bridge accepts only the 2026 Season Pack packet format (header format 2026) and validates packet lengths before parsing. It never substitutes demo or generated live telemetry. Unsupported or unavailable fields remain `--` / `UNAVAILABLE`.

Implemented packet paths: session, lap data, car telemetry, car status, and car telemetry 2, using the official 2026 structures. The screen shows speed, gear, RPM/shift LEDs, throttle/brake, lap time, position, fuel, ERS energy, tyre surface temperatures, flags where supplied, safety-car state/delta, and active-aero state. Car telemetry 2 is decoded only for documented 2026 fields, including active aero and overtake status.

Track auto-detection uses the session track ID. A circuit outline is deliberately not fabricated: map calibration and recorded-lap map generation are not implemented yet. Mini-sector benchmarking, local lap recording/export, replay and corner advice are also not implemented yet. Those areas show unavailable/calibrating states rather than invented data. Straight Mode activation is not claimed unless the packet explicitly provides the state; current published structures provide active-aero zones/status and overtake data, not a universal field named Straight Mode.

## Start on the gaming PC

1. Install Python 3.10 or newer. No third-party packages are required.
2. In F1 25 settings, enable UDP telemetry, choose **F1 25: 2026 Season Pack** UDP mode, set format to **2026**, and choose a UDP port (default `20777`). Set telemetry to public if multiplayer requires it.
3. Download/clone this repository and run `python bridge.py` from its directory. It listens on UDP `0.0.0.0:20777` and serves the display and WebSocket on port `8080`.
4. Find the gaming PC's LAN IPv4 address. On the phone connected to the same Wi-Fi, open `http://<PC-IP>:8080` and tap **CONNECT**.
5. Allow Python through the PC firewall on the private network. Keep the bridge running while the game is open.

The bridge serves the page and WebSocket from the same HTTP host. The app requires a modern browser with WebSocket support. Use the fullscreen button and landscape orientation for driving.

Set `F1_UDP_PORT` and `HTTP_PORT` environment variables to change the default ports.

## UDP reference

EA's official page links the version 11.0 2026 Season Pack structures. The parser uses little-endian fields and the 29-byte packet header, expects `m_packetFormat == 2026`, and rejects legacy 2025 packets. See [EA official UDP specification](https://forums.ea.com/blog/f1-games-game-info-hub-en/ea-sports%E2%84%A2-f1%C2%AE25-2026-season-pack-udp-specification/12187347).

## GitHub Pages

`index.html` is a static fallback. GitHub Pages cannot receive game UDP packets; live telemetry requires the local bridge. A hosted HTTPS page cannot connect to this local HTTP WebSocket without browser mixed-content restrictions, so use the bridge-served page for live driving.
