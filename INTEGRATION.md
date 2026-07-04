# Integrating WinlinkKit into Ham-Tools

How to embed WinlinkKit as the Winlink module of a host app (written with
Ham-Tools in mind, but nothing here is specific to it).

## 1. SPM dependency

```swift
// Ham-Tools/Package.swift (or Xcode ▸ Package Dependencies)
dependencies: [
    .package(url: "https://github.com/<you>/WinlinkKit.git", from: "0.1.0"),
    // During development, a local path is more convenient:
    // .package(path: "../WinlinkKit"),
],
targets: [
    .target(name: "HamTools", dependencies: ["WinlinkKit"]),
]
```

WinlinkKit has no transitive dependencies (Foundation, Network, CryptoKit only),
so it adds nothing to the app's dependency graph.

## 2. The three integration points

The public API is deliberately small. An app touches exactly three things:

| You provide | WinlinkKit provides |
|---|---|
| a `MailboxHandler` implementation | `B2Message` (compose/parse), `B2FSession` (exchange), `TelnetTransport` (connect) |
| the user's callsign + Winlink password | secure login, proposals, compression, framing |
| a trigger ("check mail now") | one full B2F exchange per call |

### Composing a message

```swift
var message = B2Message(mycall: settings.callsign)
message.addTo("N0CALL")                  // or "someone@example.com"
message.setSubject(subjectField.text)
message.setBody(bodyField.text + "\n")
message.addFile(B2File(name: "photo.jpg", data: jpegData)) // optional
try await mailbox.addOutbound(message)   // your MailboxHandler
```

### Running an exchange

```swift
func checkWinlinkMail() async throws -> TrafficStats {
    let transport = try await TelnetTransport.dialCMS(mycall: settings.callsign)

    let session = B2FSession(
        mycall: settings.callsign,
        targetcall: TelnetTransport.cmsTargetCall,
        locator: settings.locator,
        mailbox: mailbox
    )
    session.secureLoginPassword = try keychain.winlinkPassword()
    session.logLine = { line in Logger.winlink.debug("\(line)") }

    return try await session.exchange(over: transport)
}
```

**A `B2FSession` is single-use.** Create a fresh session and transport for every
exchange; the transport is closed automatically when the exchange ends (also on
error). Errors are typed (`WinlinkError`); `error.isLoginFailure` detects a
wrong password specifically.

## 3. Mailbox persistence

`DirectoryMailbox` (bundled) stores messages as `.b2f` files and is fine for
testing. For Ham-Tools, implement `MailboxHandler` on top of the app's own
store (Core Data/SQLite/GRDB) instead — the protocol is six methods:

```swift
actor HamToolsMailbox: MailboxHandler {
    func prepare() async throws { /* open store, migrate if needed */ }

    func outboundMessages(for forwarders: [Address]) async -> [B2Message] {
        // All queued messages; if `forwarders` is non-empty (P2P, stage 2),
        // only those addressed exclusively to one of them.
    }

    func markSent(_ mid: String, rejected: Bool) async {
        // Move from outbox to sent. `rejected` = remote already had it.
    }

    func markDeferred(_ mid: String) async {
        // Keep queued; the remote wants it later.
    }

    func processInbound(_ message: B2Message) async throws {
        // Persist. Throwing here reports the failure to the remote,
        // and the message will be offered again next session.
    }

    func inboundAnswer(for proposal: Proposal) async -> ProposalAnswer {
        // .reject if proposal.messageID is already in the store
        // (deduplication!), otherwise .accept.
    }
}
```

Two rules matter:

1. **Deduplicate by MID** in `inboundAnswer(for:)` — the CMS offers a message
   again if a previous session died mid-transfer.
2. **Persist before returning** from `processInbound` — once the session
   completes, the CMS deletes its copy. If you lose the message after
   accepting it, it's gone.

Store the raw wire form (`try message.bytes()`) alongside your parsed model if
you want lossless round-trips.

## 4. Threading model

- The whole API is `async/await`; there are no callbacks except the optional
  `logLine` closure (called on the session's task, keep it cheap and `@Sendable`).
- `B2FSession` is **not** `Sendable` — create, configure and use it within one
  task. The natural shape is one `Task { try await checkWinlinkMail() }` per
  exchange, e.g. from a "Check mail" button or a timer.
- `MailboxHandler` implementations must be `Sendable`; an `actor` is the
  easiest correct choice.
- `TelnetTransport` is an actor and handles its own I/O queue. Nothing in
  WinlinkKit blocks a thread; it is safe to call from the main actor context
  (the awaits suspend, not block).
- Run **one exchange at a time** per account. Concurrent sessions for the same
  callsign would race on the mailbox and confuse the CMS.

## 5. Credentials

- The Winlink account password is only held in memory on the session
  (`secureLoginPassword`) and used to answer the `;PQ` challenge (MD5, as the
  protocol mandates). It is never written to disk or logged by WinlinkKit.
- Store it in the Keychain on the app side.
- The telnet login password (`CMSTelnet`) is a protocol constant, not a secret.

## 6. Operational notes

- **Client registration:** production CMS servers reject unregistered client
  SIDs. Until the WinlinkKit name is registered with the Winlink Development
  Team, exchanges must go to `cms-z.winlink.org` (pass `host:` to `dialCMS`).
  Once Ham-Tools ships its own SID name, register that name too
  (`session.userAgent = (name: "HamTools", version: appVersion)` — no dashes).
- **Message precedence:** subjects starting with `//WL2K Z/`, `O/`, `P/` are
  sent first (Flash/Immediate/Priority) — relevant for emergency traffic.
- **Stage 2** (VARA, ARDOP, AX.25, rigctld PTT) will arrive as additional
  `WinlinkTransport` implementations; the session API stays unchanged. See
  [BACKLOG.md](BACKLOG.md).
