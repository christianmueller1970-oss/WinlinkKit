# Backlog — Stage 2 and beyond

Items deliberately deferred during stage 1 (Telnet-only). Roughly in the order
they will likely be tackled. Reference implementations for almost everything:
[wl2k-go](https://github.com/la5nta/wl2k-go) (transports) and
[Pat](https://github.com/la5nta/pat) (client behavior).

## Administrative

- [ ] **Register the client type** with the Winlink Development Team so the
      `WinlinkKit` SID name is accepted on production CMS servers
      (`server.winlink.org`). Until then: `cms-z.winlink.org` only.
      Draft email: see `docs/winlink-registration-draft.md`.
- [ ] Complete the live receive test (was blocked by a Winlink-side delivery
      lag on 2026-07-04; send path is verified).

## Radio transports (the core of stage 2)

- [ ] **VARA HF/FM** — TCP command port 8300 (FM: 8301) + data port,
      `wl2k-go/transport/varahf`. Most relevant for HB9AF use.
- [ ] **ARDOP** — TCP 8515/8516, `wl2k-go/transport/ardop`.
- [ ] **AX.25 via AGWPE/Direwolf** — `wl2k-go/transport/ax25/agwpe`.
- [ ] **rigctld PTT/frequency control** (Hamlib network protocol) — needed by
      all radio transports; keep it a separate small module.
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

- [ ] **RMS/gateway list** via the Winlink Web Services API (channel list by
      band/mode/distance) so the app can offer "nearest VARA gateway".
- [ ] Account existence check / password recovery hints via Web Services.

## Housekeeping

- [ ] P2P server mode (accept inbound connections as the "master" side is
      implemented and tested, but has no listener/transport entry point).
- [ ] Performance pass over LZHUF (correctness-first port; encoder speed is
      fine for mail-sized payloads, but was never profiled).
- [ ] DocC catalog (`.docc` bundle) with articles, once the API stabilizes.
- [ ] CI (GitHub Actions: `swift build && swift test` on macOS).
