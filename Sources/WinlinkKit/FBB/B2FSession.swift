// Ported from wl2k-go/fbb/wl2k.go, handshake.go and b2f.go
import Foundation

/// Message traffic statistics of an exchange (Go: TrafficStats).
public struct TrafficStats: Sendable, Equatable {
    /// MIDs of successfully received messages.
    public internal(set) var received: [String] = []
    /// MIDs of successfully sent messages.
    public internal(set) var sent: [String] = []
}

/// A B2F exchange session (Go: Session).
///
/// A session must only be used once: create it, configure it, then call
/// `exchange(over:)`. It talks exclusively to a `WinlinkTransport` and
/// never to a concrete network type.
public final class B2FSession {
    /// The session state machine. Transitions:
    ///
    ///     initial ──exchange()──▶ handshake
    ///     handshake ──SIDs and login exchanged──▶ ourTurn | theirTurn
    ///       (master starts with theirTurn, client with ourTurn)
    ///     ourTurn ──proposals/messages sent──▶ theirTurn
    ///     ourTurn ──FQ sent──▶ done
    ///     theirTurn ──proposals/messages received──▶ ourTurn
    ///     theirTurn ──FQ received──▶ done
    ///     any ──error──▶ done (error echoed to remote, connection closed)
    enum State: Equatable {
        case initial
        case handshake
        case ourTurn
        case theirTurn
        case done
    }

    private let mycall: String
    private let targetcall: String
    private let locator: String
    private let mailbox: (any MailboxHandler)?

    /// True if this end initiates the handshake. Stations connecting to a
    /// CMS are never master (Go: IsMaster).
    public var isMaster = false

    /// Lines sent before the handshake when master (Go: SetMOTD).
    public var motd: [String] = []

    /// The password used to answer a secure login challenge (;PQ).
    /// Stage 1 supports a single account password; per-address callbacks
    /// for auxiliary addresses are a stage-2 item (Go: SecureLoginHandleFunc).
    public var secureLoginPassword: String?

    /// Name and version reported in our SID. Must not contain dashes
    /// (Go: UserAgent).
    public var userAgent = (name: "WinlinkKit", version: WinlinkKit.version)

    /// Optional sink for protocol log lines (`>` prefix marks sent lines).
    public var logLine: (@Sendable (String) -> Void)?

    private(set) var state: State = .initial
    private var remoteSID: SID?

    /// Addresses the remote requests messages on behalf of. Empty when the
    /// remote is a Winlink CMS. Available after the handshake (Go: RemoteForwarders).
    public private(set) var remoteForwarders: [Address] = []

    /// Addresses we request messages on behalf of (Go: localFW).
    private let localForwarders: [Address]

    /// MID to pending message details (;PM winlink extension).
    private var pendingMessages: [String: PendingMessage] = [:]

    private var remoteNoMsgs = false // True if last remote turn had no more messages
    private var stats = TrafficStats()

    private var transport: (any WinlinkTransport)?
    private var reader: TransportReader?

    /// Creates a new session. Calls are upper-cased (Go: NewSession).
    public init(
        mycall: String, targetcall: String, locator: String,
        mailbox: (any MailboxHandler)? = nil
    ) {
        self.mycall = mycall.uppercased()
        self.targetcall = targetcall.uppercased()
        self.locator = locator
        self.mailbox = mailbox
        self.localForwarders = [Address(string: mycall.uppercased())]
    }

    // MARK: - Exchange

    /// Exchanges messages with the remote over the B2F protocol
    /// (Go: Exchange).
    ///
    /// Sends outbound messages from the mailbox and downloads inbound
    /// messages into it. The transport is closed at the end of the
    /// exchange. On a protocol error, the error is echoed to the remote
    /// (`*** ...`) before closing, like wl2k-go does.
    @discardableResult
    public func exchange(over transport: any WinlinkTransport) async throws -> TrafficStats {
        guard state == .initial else { return stats } // A session is single-use.

        self.transport = transport
        self.reader = TransportReader(transport)

        do {
            try await mailbox?.prepare()

            state = .handshake
            try await handshake()

            // Alternate turns until one side has sent FQ. The connecting
            // station (non-master) speaks first after the handshake.
            var myTurn = !isMaster
            var quitSent = false
            var quitReceived = false
            while !quitSent && !quitReceived {
                state = myTurn ? .ourTurn : .theirTurn
                if myTurn {
                    quitSent = try await handleOutbound()
                } else {
                    quitReceived = try await handleInbound()
                }
                myTurn.toggle()
            }

            state = .done
            await transport.close()
            return stats
        } catch {
            state = .done
            // Echo protocol errors to the remote peer before disconnecting.
            // Connection-loss errors are pointless to echo (Go: Exchange's defer).
            if (error as? WinlinkError) != .connectionClosed {
                try? await transport.write(Data("*** \(error)\r\n".utf8))
            }
            await transport.close()
            throw error
        }
    }

    /// The remote's SID line features (if the handshake completed).
    public var remoteSIDFeatures: String? { remoteSID?.features }

    // MARK: - Handshake (Go: handshake.go)

    private func handshake() async throws {
        if isMaster {
            for line in motd {
                try await write(line + protocolCR)
            }
            try await sendHandshake(challenge: nil)
        }

        let hs = try await readHandshake()
        guard let sid = hs.sid else {
            throw WinlinkError.malformedInput("No SID in handshake")
        }
        remoteSID = sid
        remoteForwarders = hs.forwarders

        if !isMaster {
            try await sendHandshake(challenge: hs.secureChallenge)
        }
    }

    private struct HandshakeData {
        var sid: SID?
        var forwarders: [Address] = []
        var secureChallenge: String?
    }

    private func readHandshake() async throws -> HandshakeData {
        var data = HandshakeData()

        while true {
            guard let reader else { throw WinlinkError.connectionClosed }

            // As master, a protocol command line means the handshake is done.
            if try await reader.peekByte() == UInt8(ascii: "F"), isMaster {
                return data
            }

            // Don't treat `*`-lines as errors here: the server sends
            // status lines like '*** MTD Stats ...' during the handshake.
            let line = try await nextLine(parseRemoteError: false)

            if SID.isSIDLine(line) {
                let sid = try SID(parsing: line)
                try sid.requireB2F() // We require B2F, abort early otherwise.
                data.sid = sid
            } else if line.hasPrefix(";FW") {
                data.forwarders = try Self.parseFW(line)
            } else if line.hasPrefix(";PQ") {
                data.secureChallenge = String(line.dropFirst(5))
            } else if line.hasSuffix(">") { // Prompt
                return data
            }
            // Everything else is ignored.
        }
    }

    private func sendHandshake(challenge: String?) async throws {
        var response: String?
        if let challenge {
            guard let password = secureLoginPassword else {
                throw WinlinkError.malformedInput(
                    "Got secure login challenge, but no password is set")
            }
            response = SecureLogin.response(challenge: challenge, password: password)
        }

        // Request messages on behalf of every local forwarder.
        var out = ";FW:"
        for addr in localForwarders {
            // Password hashes for auxiliary addresses are a stage-2 item;
            // stage 1 only ever has a single forwarder (mycall).
            out += " " + addr.addr
        }
        out += protocolCR

        out += SID.localLine(name: userAgent.name, version: userAgent.version) + protocolCR

        if let response {
            out += ";PR: " + response + protocolCR
        }

        out += "; \(targetcall) DE \(mycall) (\(locator))"
        out += isMaster ? ">" + protocolCR : protocolCR

        try await write(out)
    }

    /// Parses a `;FW: <addr> <addr|hash> ...` line (Go: parseFW).
    static func parseFW(_ line: String) throws -> [Address] {
        guard line.hasPrefix(";FW: ") else {
            throw WinlinkError.malformedInput("Malformed forward line")
        }
        return line.dropFirst(5)
            .split(separator: " ", omittingEmptySubsequences: false)
            .map { part in
                // Strip password hashes (unsupported).
                Address(string: String(part.split(separator: "|")[0]))
            }
    }

    // MARK: - Outbound (Go: b2f.go handleOutbound/sendOutbound)

    /// Sends our proposals and messages, or FF/FQ if there is nothing to
    /// send. Returns true if FQ was sent (Go: handleOutbound).
    private func handleOutbound() async throws -> Bool {
        var outbound = await outboundProposals()

        if outbound.isEmpty {
            // No outbound messages: send FF, or FQ if the remote is also empty.
            let resp = remoteNoMsgs ? "FQ" : "FF"
            try await write(resp + protocolCR)
            return remoteNoMsgs
        }

        var sent = try await sendOutbound(&outbound)

        // Report rejected now; they can safely be marked even if an error occurs.
        for (mid, rejected) in sent where rejected {
            await mailbox?.markSent(mid, rejected: true)
            sent[mid] = nil
        }

        // Error reporting from the remote is not defined by the protocol,
        // but usually indicated by a '***'-prefixed line. The only valid
        // bytes after a session turnover are 'F' or ';', so we use those
        // to confirm the block was successfully received.
        guard let reader else { throw WinlinkError.connectionClosed }
        let p = try await reader.peekByte()
        if p != UInt8(ascii: "F"), p != UInt8(ascii: ";") {
            let line = try await nextLine()
            throw WinlinkError.malformedInput("Unexpected response: '\(line)'")
        }

        // Report successfully sent messages.
        for (mid, rejected) in sent {
            await mailbox?.markSent(mid, rejected: rejected)
            if !rejected {
                stats.sent.append(mid)
            }
        }

        return false
    }

    /// Collects, validates and sorts the outbound proposals (Go: outbound).
    private func outboundProposals() async -> [Proposal] {
        guard let mailbox else { return [] }

        let messages = await mailbox.outboundMessages(for: remoteForwarders)
        var proposals = [Proposal]()
        for message in messages {
            do {
                proposals.append(try message.proposal())
            } catch {
                // It seems reasonable to ignore these with a warning.
                logLine?("Ignoring invalid outbound message '\(message.mid)': \(error)")
            }
        }
        Proposal.sort(&proposals)
        return proposals
    }

    /// Sends one block of proposals (max `MaxBlockSize`), awaits the FS
    /// answer and transfers the accepted messages. Returns a map from MID
    /// to whether the remote rejected it (Go: sendOutbound).
    private func sendOutbound(_ outbound: inout [Proposal]) async throws -> [String: Bool] {
        var sent = [String: Bool]()

        if outbound.count > MaxBlockSize {
            outbound = Array(outbound.prefix(MaxBlockSize))
        }

        var block = ""
        for prop in outbound {
            logLine?(">\(prop.proposalLine)")
            block += prop.proposalLine + protocolCR
        }
        let checksum = Proposal.blockChecksum(overLines: outbound.map(\.proposalLine))
        let prompt = String(format: "F> %02X", checksum)
        logLine?(">\(prompt)")
        block += prompt + protocolCR
        try await write(block, raw: true)

        // Await the proposal answer (FS ...), storing ;PM details and
        // skipping comments on the way.
        var reply = ""
        while reply.isEmpty {
            let line = try await nextLine()
            if line.hasPrefix("FS ") {
                reply = line
            } else if line.hasPrefix(";PM") {
                if let pm = try? PendingMessage(parsing: line) {
                    pendingMessages[pm.mid] = pm
                }
            } else if line.hasPrefix(";") {
                continue // Ignore comment
            } else {
                throw WinlinkError.malformedInput(
                    "Expected proposal answer from remote. Got: '\(line)'")
            }
        }

        try Proposal.applyAnswers(reply, to: &outbound)

        for prop in outbound {
            switch prop.answer {
            case .defer_:
                await mailbox?.markDeferred(prop.messageID)
            case .reject:
                sent[prop.messageID] = true
            case .accept:
                try await writeCompressed(prop)
                sent[prop.messageID] = false
            }
        }
        return sent
    }

    // MARK: - Inbound (Go: b2f.go handleInbound)

    /// Receives a proposal block, answers it and downloads the accepted
    /// messages. Returns true if FQ was received (Go: handleInbound).
    private func handleInbound() async throws -> Bool {
        var checksumLines = [String]()
        var proposals = [Proposal]()
        var quitReceived = false

        loop: while true {
            let line = try await nextLine()

            // Store pending message details (winlink extension).
            if line.hasPrefix(";PM") {
                if let pm = try? PendingMessage(parsing: line) {
                    pendingMessages[pm.mid] = pm
                }
                continue
            }

            // Ignore comments and empty lines.
            if line.isEmpty || line.hasPrefix(";") {
                continue
            }

            guard line.count >= 2, line.hasPrefix("F") else {
                throw WinlinkError.malformedInput("Got unexpected protocol line: '\(line)'")
            }

            switch String(line.prefix(2)) {
            case "FA", "FB", "FC", "FD": // Proposals
                checksumLines.append(line)
                var prop = try Proposal(parsing: line)
                if let pm = pendingMessages[prop.messageID] {
                    prop.pendingMessage = pm
                }
                proposals.append(prop)

            case "FF": // No more messages
                remoteNoMsgs = true
                break loop

            case "FQ": // Quit
                quitReceived = true
                break loop

            case "F>": // Prompt (end of proposal block)
                let ours = Proposal.blockChecksum(overLines: checksumLines)
                let theirs = Int(line.dropFirst(3), radix: 16)
                guard theirs == ours else {
                    throw WinlinkError.invalidChecksum
                }

                // No proposals means the remote has nothing for us.
                if proposals.isEmpty {
                    remoteNoMsgs = true
                    return false
                }
                remoteNoMsgs = false

                logLine?("\(proposals.count) proposal(s) received")
                try await writeProposalsAnswer(&proposals)

                // Session turnover is implied, regardless of the number
                // of accepted messages.
                break loop

            default:
                throw WinlinkError.malformedInput("Unknown protocol command '\(line.prefix(2))'")
            }
        }

        // Fetch and decompress the accepted messages.
        for i in proposals.indices where proposals[i].answer == .accept {
            try await readCompressed(&proposals[i])
            let message = try proposals[i].message()
            try await mailbox?.processInbound(message)
            stats.received.append(proposals[i].messageID)
        }

        return quitReceived
    }

    /// Answers a block of inbound proposals with an `FS` line
    /// (Go: writeProposalsAnswer).
    ///
    /// Duplicate MIDs in the same batch are deferred (Radio Only gateways
    /// send those), as are unsupported formats and — deviating from Go,
    /// which ships gzip — `FD` proposals, since gzip decompression is a
    /// stage-2 item.
    private func writeProposalsAnswer(_ proposals: inout [Proposal]) async throws {
        var seen = Set<String>()

        for i in proposals.indices {
            if seen.contains(proposals[i].messageID) {
                logLine?("Deferring duplicate message \(proposals[i].messageID)")
                proposals[i].answer = .defer_
            } else if proposals[i].code != .wl2k {
                logLine?("Deferring \(proposals[i].messageID) (unsupported format)")
                proposals[i].answer = .defer_
            } else if mailbox == nil {
                logLine?("Deferring \(proposals[i].messageID) (missing handler)")
                proposals[i].answer = .defer_
            } else if let mailbox {
                proposals[i].answer = await mailbox.inboundAnswer(for: proposals[i])
                if proposals[i].answer == .accept {
                    logLine?("Accepting \(proposals[i].messageID)")
                }
            }
            seen.insert(proposals[i].messageID)
        }

        let answers = String(proposals.map(\.answer.rawValue))
        logLine?(">FS \(answers)")
        try await write("FS \(answers)" + protocolCR)
    }

    // MARK: - Binary message transfer (Go: b2f.go writeCompressed/readCompressed)

    /// Transfers one accepted outbound message: transfer header (SOH),
    /// data blocks (STX) and checksum (EOT).
    private func writeCompressed(_ p: Proposal) async throws {
        logLine?("Transmitting [\(p.title)] [offset \(p.offset)]")

        // The title field must be ASCII-only, so word-encode it.
        let title = RFC2047.encode(p.title)
        let offset = String(p.offset)
        let headerLength = title.count + offset.count + 2

        var out = Data()
        // Like Go's byte(length): the length field is a single byte. Titles
        // are protocol-limited to 80 bytes, so this only truncates on
        // malformed input — same behavior as the Go original.
        out.append(contentsOf: [FBBControl.soh, UInt8(truncatingIfNeeded: headerLength)])
        out.append(contentsOf: B2Charset.encode(title))
        out.append(FBBControl.nul)
        out.append(contentsOf: Array(offset.utf8))
        out.append(FBBControl.nul)

        guard p.compressedSize >= 6 else { // lzhuf's smallest valid length (empty)
            throw WinlinkError.malformedInput("Invalid compressed data")
        }

        // Data blocks of at most MaxMsgLength bytes each.
        var checksum = 0
        var index = p.offset
        while index < p.compressedData.count {
            let blockLength = min(MaxMsgLength, p.compressedData.count - index)
            out.append(contentsOf: [FBBControl.stx, UInt8(blockLength)])
            for b in p.compressedData[index..<(index + blockLength)] {
                out.append(b)
                checksum += Int(b)
            }
            index += blockLength
        }

        checksum = (-checksum) & 0xff
        out.append(contentsOf: [FBBControl.eot, UInt8(checksum)])

        guard let transport else { throw WinlinkError.connectionClosed }
        try await transport.write(out)
    }

    /// Receives one accepted inbound message into the proposal's
    /// compressed data buffer, verifying length and checksum.
    private func readCompressed(_ p: inout Proposal) async throws {
        guard let reader else { throw WinlinkError.connectionClosed }

        switch try await reader.readByte() {
        case FBBControl.soh:
            break // what we expected...
        case UInt8(ascii: "*"):
            let line = try await reader.readLine()
            throw WinlinkError.remoteError("Got error from CMS: \(line)")
        case let c:
            throw WinlinkError.malformedInput("First byte not as expected, got \(c)")
        }

        let headerLength = Int(try await reader.readByte())

        // Transfer header: title NUL offset NUL. The title should be
        // ASCII-only, but RMS Express and CMS put the raw subject header
        // here — decode it like the subject header.
        let titleBytes = try await reader.readBytes(until: FBBControl.nul)
        p.title = RFC2047.decodeHeader(B2Charset.decode(titleBytes))

        let offsetBytes = try await reader.readBytes(until: FBBControl.nul)
        let offsetString = B2Charset.decode(offsetBytes)

        let actualHeaderLength = titleBytes.count + offsetBytes.count + 2
        guard headerLength == actualHeaderLength else {
            throw WinlinkError.malformedInput(
                "Header length mismatch: expected \(headerLength), got \(actualHeaderLength)")
        }

        guard let offset = Int(offsetString) else {
            throw WinlinkError.malformedInput(
                "Offset header not parseable as integer: '\(offsetString)'")
        }
        guard offset == p.offset else {
            throw WinlinkError.malformedInput("Expected offset \(p.offset), got \(offset)")
        }

        logLine?("Receiving [\(p.title)] [offset \(p.offset)]")

        var buf = [UInt8]()
        var ourChecksum = 0
        while true {
            switch try await reader.readByte() {
            case FBBControl.stx:
                var length = Int(try await reader.readByte())
                if length == 0 {
                    length = 256 // A zero length byte means a full 256-byte block.
                }
                for _ in 0..<length {
                    let b = try await reader.readByte()
                    buf.append(b)
                    ourChecksum = (ourChecksum + Int(b)) % 256
                }

            case FBBControl.eot:
                let b = try await reader.readByte()
                ourChecksum = (ourChecksum + Int(b)) % 256
                guard ourChecksum == 0 else {
                    throw WinlinkError.invalidChecksum
                }
                guard p.compressedSize == buf.count else {
                    throw WinlinkError.malformedInput("Length mismatch after EOT")
                }
                p.compressedData = buf
                return

            case let c:
                throw WinlinkError.malformedInput("Unexpected byte in compressed stream: \(c)")
            }
        }
    }

    // MARK: - Line I/O (Go: helpers.go)

    /// Reads the next protocol line, optionally turning `*`-prefixed
    /// remote error lines into thrown errors (Go: nextLine/nextLineRemoteErr).
    private func nextLine(parseRemoteError: Bool = true) async throws -> String {
        guard let reader else { throw WinlinkError.connectionClosed }
        let line = try await reader.readLine()
        logLine?(line)

        if parseRemoteError, let error = Self.remoteErrorLine(line) {
            throw error
        }
        return line
    }

    /// Extracts an error from a `*`-prefixed line (Go: errLine).
    static func remoteErrorLine(_ line: String) -> WinlinkError? {
        guard line.first == "*" else { return nil }
        guard let idx = line.lastIndex(of: "*"), line.index(after: idx) < line.endIndex else {
            return nil
        }
        let message = String(line[line.index(after: idx)...])
            .trimmingCharacters(in: .whitespaces)
        return .remoteError(message)
    }

    /// Writes a protocol string (ISO-8859-1). With `raw`, no log line is
    /// emitted (the caller already logged the pieces).
    private func write(_ string: String, raw: Bool = false) async throws {
        guard let transport else { throw WinlinkError.connectionClosed }
        if !raw {
            for line in string.split(separator: protocolCR.first!) {
                logLine?(">\(line)")
            }
        }
        try await transport.write(Data(B2Charset.encode(string)))
    }
}

/// Maximum bytes per STX data block. Paclink-unix uses 250, protocol
/// maximum is 255, but wl2k-go uses 125 to allow AX.25 links with a
/// paclen of 128 (Go: MaxMsgLength).
let MaxMsgLength = 125
