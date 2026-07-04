# WinlinkKit

A native Swift implementation of the Winlink **B2 Forwarding Protocol** (B2F) for
exchanging radio email with the Winlink 2000 system — no UI, no external
dependencies, just protocol, transport and a mailbox abstraction.

Core logic is ported from [wl2k-go](https://github.com/la5nta/wl2k-go)
(Martin Hebnes Pedersen, LA5NTA — MIT license).

## Status

**Stage 1 (current):** send and receive Winlink mail over **Telnet/TCP** to a CMS.

- ✅ B2F session state machine (handshake, secure login, proposals, binary transfer)
- ✅ LZHUF compression (bit-exact against the wl2k-go golden files)
- ✅ Winlink Message Structure (ISO-8859-1, RFC 2047 headers, attachments)
- ✅ Telnet transport with CMS prompt login
- 🔜 Stage 2: radio transports (VARA, ARDOP, AX.25/AGWPE), see [BACKLOG.md](BACKLOG.md)

> **Note:** the production CMS (`server.winlink.org`) only accepts registered
> client types. Until WinlinkKit is registered with the Winlink Development Team,
> use the test server `cms-z.winlink.org`.

## Requirements

- Swift 6, macOS 14+
- No dependencies beyond Foundation, Network.framework and CryptoKit

## Installation

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/<you>/WinlinkKit.git", from: "0.1.0")
]
```

## Usage

### Sending and fetching messages

```swift
import WinlinkKit

// A mailbox holds outbound messages and receives inbound ones.
// DirectoryMailbox stores them as .b2f files; implement MailboxHandler
// yourself to plug in your own persistence (Core Data, SQLite, ...).
let mailbox = DirectoryMailbox(root: URL(fileURLWithPath: "mailbox"))

// Compose a message.
var message = B2Message(mycall: "HB9HJI")
message.addTo("N0CALL")
message.setSubject("Greetings from JN47PN")
message.setBody("Hello from WinlinkKit!\n")
try await mailbox.addOutbound(message)

// Connect to the CMS (answers the Callsign/Password telnet prompts).
let transport = try await TelnetTransport.dialCMS(
    mycall: "HB9HJI",
    host: "cms-z.winlink.org" // test server; default is server.winlink.org
)

// Run one B2F exchange: sends everything pending, fetches everything waiting.
let session = B2FSession(
    mycall: "HB9HJI",
    targetcall: TelnetTransport.cmsTargetCall,
    locator: "JN47PN",
    mailbox: mailbox
)
session.secureLoginPassword = winlinkPassword // your Winlink account password

let stats = try await session.exchange(over: transport)
print("sent: \(stats.sent), received: \(stats.received)")
```

A `B2FSession` is single-use: create a new one for every connection.
Everything is `async/await`; the session only ever talks to the
`WinlinkTransport` protocol, so radio transports can be added without
touching the session (stage 2).

### Command line tool

The package ships a small CLI for manual end-to-end testing:

```bash
export WL_CALLSIGN=HB9HJI
export WL_PASSWORD='your-winlink-password'   # single quotes!
export WL_LOCATOR=JN47PN
export WL_CMS_HOST=cms-z.winlink.org

swift run winlinkkit-cli send --to N0CALL --subject "Test" --body "Hello"
swift run winlinkkit-cli fetch
```

Credentials are only ever read from the environment — never stored, never logged.

## Architecture

```
B2FSession  ──── talks to ────▶  WinlinkTransport (protocol)
    │                                   ▲
    │ uses                              │ implements
    ▼                                   │
MailboxHandler (protocol)        TelnetTransport (stage 1)
    ▲                            VARA/ARDOP/AX.25 (stage 2)
    │ implements
DirectoryMailbox (or your own)
```

- `B2Message` — the Winlink Message Structure (headers, body, attachments)
- `Proposal` — FC/FS/FF/FQ proposal handling with block checksums
- `LZHUF` — the FBB compression (LZ77 + adaptive Huffman) with B2 framing
- `B2FSession` — the exchange state machine (explicit `enum State`)

See [INTEGRATION.md](INTEGRATION.md) for embedding WinlinkKit in an app.

## Testing

```bash
swift test
```

The test suite includes golden-file tests for LZHUF (byte-identical encode and
decode against the wl2k-go test data), the ported wl2k-go unit tests, and
scripted B2F sessions against an in-memory pipe transport — including full
peer-to-peer message transfers, secure login, checksum failures and
connection loss.

## License

MIT — see [LICENSE](LICENSE). Portions ported from
[wl2k-go](https://github.com/la5nta/wl2k-go), © Martin Hebnes Pedersen LA5NTA (MIT).

*73 de HB9HJI*
