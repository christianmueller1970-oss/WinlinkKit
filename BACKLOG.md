# Backlog — Stage 2 and beyond

Items deliberately deferred during stage 1 (Telnet-only). Roughly in the order
they will likely be tackled. Reference implementations for almost everything:
[wl2k-go](https://github.com/la5nta/wl2k-go) (transports) and
[Pat](https://github.com/la5nta/pat) (client behavior).

## Administrative

- [x] **Register the client type** with the Winlink Development Team so the
      `WinlinkKit` SID name is accepted on production CMS servers
      (`server.winlink.org`). Done: `WinlinkKit` and `Skywave` SIDs live on
      production since 2026-07-13 (Rob, WDT); both confirmed the same day —
      Skywave via app round trip, WinlinkKit via `winlinkkit-cli` fetch.
- [x] Complete the live receive test — verified 2026-07-13 on production via
      the Skywave app: send to external and receive from external both worked.

## Radio transports (the core of stage 2)

> **Strategy decision (Chris, 2026-07-05):** Ham-Tools only ships features
> that run fully native on the Mac — no companion hardware (Pi/Windows box).
> Therefore Ham-Tools integrates **telnet only** for now. The radio
> transports below stay in WinlinkKit (complete, unit-tested, usable via
> the CLI) but are not wired into Ham-Tools until a native modem path
> exists. For RF, Chris uses his existing Winlink setup on Windows.
>
> - Native HF path: ✅ **DONE 2026-07-14** — ardopcf ported to macOS
>   (PortAudio backend, fork in `~/Developer/ardopcf`, branch
>   `macos-port`); `ArdopProcess` runs it as a managed child, Skywave
>   bundles the universal binary. VARA is closed-source Windows-only —
>   no native path, ever.
> - Native VHF path: **Direwolf builds natively on macOS** → the AX.25/AGWPE
>   transport would be fully native (radio + audio interface only, no
>   extra computer).

- [x] **VARA HF/FM** — TCP command port 8300 (FM: 8301) + data port,
      `wl2k-go/transport/varahf`. Live RF test to HB9AK succeeded 2026-07-05.
- [x] **ARDOP** — TCP 8515/8516, `wl2k-go/transport/ardop`. TCP only (no
      serial CRC framing); heard-station tracking and listen mode not ported.
      **Live RF test passed 2026-07-18** (Skywave milestone H6): bundled
      ardopcf → HB9AK via 80 m, CI-V QSY + restore, CAT PTT, full B2F
      exchange, ARQ quality 99, 0 failed decodes.
- [ ] **AX.25 via AGWPE/Direwolf** — `wl2k-go/transport/ax25/agwpe`.
- [x] **rigctld PTT/frequency/mode control** (Hamlib network protocol) —
      `RigctldClient`, wired to ARDOP PTT in the CLI via WL_RIGCTLD_HOST.
      Mode added in 0.3.1 so a QSY works over a *shared* rigctld while
      another program holds the serial port — without it the rig lands
      on the right frequency but stays in SSB.
- [x] **CI-V frequency/mode control** (Icom CAT on the rig's serial
      port) — `CIVClient` over the new `SerialTransport`; reads/sets
      dial frequency and mode incl. data mode (cmd 26 00). Powers
      Skywave's gateway-picker QSY (set before ardopcf starts, restore
      after it stops). `winlinkkit-cli civ` is the wiring test.
      Added 2026-07-18.
- [ ] Transport-level niceties the session already anticipates but ignores:
      robust-mode toggling (Go: `transport.Robust`), TX buffer draining
      (Go: `transport.Flusher`/`TxBuffer`) for accurate over-the-air progress.

## Protocol features

- [ ] **Resume offsets**: currently offsets are parsed but outbound resume is
      not requested and inbound offset requests > 0 restart from 0. Implement
      `A<offset>` answers and partial-data buffering (Go: fbb/b2f.go).
- [ ] **Gzip proposals (`FD`)**: parse exists; add gzip (de)compression and
      accept them (Go: GZIP_EXPERIMENT). Low priority — CMS default is LZHUF.
- [ ] **Auxiliary addresses (;FW with password hashes)**: request mail for
      more than one callsign per session (Go: sendHandshake aux handling).
      Needs per-address passwords → replace `secureLoginPassword: String?`
      with a handler closure like Go's `SecureLoginHandleFunc`.
- [ ] **Transfer progress reporting**: a `StatusUpdater`-like callback with
      bytes transferred/total, for UI progress bars (Go: wl2k.go Status).
      Trivial over telnet, matters over radio.
- [ ] **B1/basic protocol proposals (`FA`/`FB`)**: currently deferred forever.
      Only needed for very old BBS peers — probably never.

## Winlink ecosystem services (HTTP, not B2F)

- [x] **RMS/gateway list** via the Winlink Web Services API (channel list by
      band/mode/distance) so the app can offer "nearest VARA gateway".
      `GatewayWebService` queries `gateway/proximity`, one request per mode;
      `Maidenhead` supplies distance and bearing, `GatewayBandwidth` maps the
      `Baud` field. `winlinkkit-cli gateways --raw` is the probe. Access key
      granted by Rob (WDT) 2026-08-07 for `GatewayChannelReport`,
      `GatewayListing` and `GatewayProximity`, with the explicit condition
      that the endpoints be queried sparingly — hence the rate limit inside
      the actor rather than in the client.
- [x] **The `Mode` integer is resolved.** It is ARSFI's `ModeMappings`
      enum, which *does* have explicit numeric values (ARDOP200=40 …
      ARDOP2000=43, VARA500=53, VARA2750=54) — a different enum from the
      valueless `GatewayOperatingMode` we send in the request. Live data
      2026-08-07 returned 41 and 43 for ARDOP. `GatewayChannelMode` decodes
      it and is the only source of a channel's bandwidth: `Baud` is not, it
      reads "600" for ARDOP 500 and ARDOP 2000 alike.
- [ ] **Collapse the per-mode requests into one `AnyAll` request.** Now
      that the response mode is trustworthy, the transport family can be
      derived from it instead of from what was asked, so all modes could
      come back in a single call. Would cut the request count further.
- [ ] **`gateway/status.json`** if that permission is ever granted. It
      reports `SupportedModes` in plain text ("ARDOP 2000"), which would
      settle both the mode integer and the bandwidth in one go, plus
      operating hours and antenna — and it needs one request per day instead
      of one per mode. Pat uses exactly this endpoint. Would slot in behind
      the existing `GatewayWebService` facade as a second source.
- [ ] Account existence check / password recovery hints via Web Services.

## Housekeeping

- [ ] P2P server mode (accept inbound connections as the "master" side is
      implemented and tested, but has no listener/transport entry point).
- [ ] Performance pass over LZHUF (correctness-first port; encoder speed is
      fine for mail-sized payloads, but was never profiled).
- [ ] DocC catalog (`.docc` bundle) with articles, once the API stabilizes.
- [ ] CI (GitHub Actions: `swift build && swift test` on macOS).
