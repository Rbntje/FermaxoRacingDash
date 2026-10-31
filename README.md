# FERMAXO RACING · F1 2026 DISPLAY

A phone-first, single-screen telemetry instrument for EA SPORTS F1 25 with the 2026 Season Pack UDP mode.

## Current implementation

This repository was empty when the rebuild started. It now contains a responsive display and a local Python HTTP/WebSocket/UDP bridge using only the Python standard library. The parser requires header format 2026 and exact packet lengths for EA's version 11.0 structures. It rejects legacy 2025 data and does not generate live values.

Parsed packets include session, lap data, events, car telemetry, car status, car damage, time trial and Car Telemetry 2. Available values include speed, gear, RPM/shift LEDs, throttle/brake, lap and sector timing, position, fuel, ERS stored/harvested/deployed energy, tyre temperatures/wear/compound, Safety Car/VSC, car flags and active aero/overtake. Missing fields stay unavailable. Straight Mode reads the explicit m_activeAeroMode field in Car Telemetry 2.

The circuit ID is detected from session telemetry. No outline is invented: track-map calibration from a recorded lap, live position on the map, mini-sector timing/heatmap and per-track performance storage are not implemented. Lap recording/export/replay, tyre pressures, corner advice, full flag event coverage and VSC speed estimates are also not implemented. Best lap is only available from the time-trial personal-best packet. The battery percentage is not calculated because this implementation does not assume a maximum store capacity. Unavailable items remain -- or show an explicit unavailable/calibrating state.

## Start on the gaming PC

1. Install Python 3.10 or newer. No third-party packages are required.
2. In F1 25 settings, enable UDP telemetry, choose **F1 25: 2026 Season Pack** mode, use the 2026 packet format, and set a UDP port (default 20777). Set telemetry to public if multiplayer requires it.
3. Download or clone the repository and run python bridge.py. It listens on UDP 0.0.0.0:20777 and serves the display and WebSocket on port 8080.
4. Find the gaming PC's LAN IPv4 address. On the phone connected to the same Wi-Fi, open http://<PC-IP>:8080 and tap **CONNECT**.
5. Allow Python through the PC firewall on the private network. Keep the bridge running while the game is open.

The page and WebSocket use the same local host. Use the fullscreen button and landscape orientation while driving. The display reconnects automatically after a brief connection loss.

Set F1_UDP_PORT and HTTP_PORT environment variables to change the default ports.

## UDP reference

EA's official page links the version 11.0 2026 Season Pack structures. The parser uses little-endian fields and the 29-byte packet header, expects m_packetFormat == 2026, and rejects legacy 2025 packets: https://forums.ea.com/blog/f1-games-game-info-hub-en/ea-sports%E2%84%A2-f1%C2%AE25-2026-season-pack-udp-specification/12187347

## GitHub Pages

index.html is a static fallback. GitHub Pages cannot receive game UDP packets; live telemetry requires the local bridge. A hosted HTTPS page cannot connect to this local HTTP WebSocket without browser mixed-content restrictions, so use the bridge-served page for live driving.
 

## iPhone app (free sideload build)

The iPhone target receives format-2026 UDP directly from the PlayStation on the same Wi-Fi and renders the bundled Fermaxo dashboard. No PC service or cloud host is needed while driving. Keep Fermaxo open in the foreground so iOS does not suspend its UDP listener.

A macOS GitHub Actions runner builds an unsigned IPA. In GitHub, open **Actions → Build Fermaxo iPhone app → Run workflow**, then download the **FermaxoRacing-unsigned-ipa** artifact. Install it using AltStore on Windows with your free Apple Account. Free Apple provisioning expires after seven days, so AltStore/AltServer must refresh the app regularly. The PC is only for installing or refreshing the app; telemetry goes directly from PS5 to iPhone.

On iPhone, allow Local Network access when prompted. Open Fermaxo's connection settings to see the iPhone IP, then set F1 25 UDP Telemetry On, Broadcast Off, the displayed IP/port, 20 Hz, and UDP Format 2026. The PS5 and iPhone must stay on the same Wi-Fi network.



## Local JSON API

When `bridge.py` is running, the read-only API is available on the same LAN host:

- `GET http://<PC-IP>:8080/api/telemetry` — latest parsed F1 telemetry as JSON.
- `GET http://<PC-IP>:8080/api/health` — bridge status, last update time, and UDP port.
- `GET http://<PC-IP>:8080/api/openapi.json` — OpenAPI 3.1 description for both REST endpoints.
- Existing `/ws` WebSocket endpoint continues to stream live snapshots.

Use REST for polling and WebSocket for live updates. This API is served only by the running local bridge; it is not a cloud service. The native iPhone app receives PS5 UDP directly and does not require the Python bridge.
