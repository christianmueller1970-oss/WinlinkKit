// Ported from wl2k-go/fbb/proposal.go (and block helpers from b2f.go)
import Foundation

/// The B2F protocol does not support offsets larger than 6 digits.
let ProtocolOffsetSizeLimit = 999_999

/// Maximum number of proposals per block (before the `F>` prompt).
let MaxBlockSize = 5

/// The proposal code (Go: PropCode).
enum PropCode: Character, Sendable {
    case basic = "B"  // Basic ASCII proposal (or compressed binary in v0/1)
    case ascii = "A"  // Compressed v0/1 ASCII proposal
    case wl2k = "C"   // Compressed v2 proposal (winlink extension)
    case gzip = "D"   // Gzip compressed v2 proposal (unsupported, deferred)
}

/// Answer to a proposal (Go: ProposalAnswer).
public enum ProposalAnswer: Character, Sendable {
    case accept = "+"
    case reject = "-"
    case defer_ = "="
}

/// An inbound or outbound message proposal (Go: Proposal).
public struct Proposal: Sendable {
    var code: PropCode = .wl2k
    var msgType: String = "EM"
    private(set) var mid: String = ""
    var answer: ProposalAnswer = .defer_
    // Internal set: the session fills the title in from the transfer
    // header when receiving (Go: readCompressed).
    var title: String = ""
    var offset: Int = 0
    private(set) var size: Int = 0
    private(set) var compressedSize: Int = 0
    var compressedData: [UInt8] = []

    /// Optional extra information for pending messages (;PM winlink extension).
    public internal(set) var pendingMessage: PendingMessage?

    /// The unique Message ID.
    public var messageID: String { mid }

    /// The title (subject) of this proposal.
    public var proposalTitle: String { title }

    /// The size of the uncompressed message in bytes.
    public var uncompressedSize: Int { size }

    /// True if the compressed data is completely downloaded/loaded
    /// and ready to be read/sent (Go: DataIsComplete).
    var dataIsComplete: Bool { compressedData.count == compressedSize }

    init() {}

    /// Constructs an outbound proposal from raw (uncompressed) message
    /// bytes (Go: NewProposal). Only `.wl2k` (LZHUF) is supported; gzip
    /// proposals are a stage-2 backlog item.
    init(mid: String, title: String, data: Data) {
        self.mid = mid
        self.title = title.isEmpty ? "No title" : title
        self.size = data.count
        self.compressedData = [UInt8](LZHUF.encode(data, b2: true))
        self.compressedSize = compressedData.count
    }

    /// Parses a proposal line, e.g. `FC EM TJKYEIMMHSRB 527 123 0`
    /// (Go: parseProposal + parseB2Proposal).
    init(parsing line: String) throws {
        guard line.count >= 2, line.hasPrefix("F") else {
            throw WinlinkError.malformedInput("Not a proposal line: \(line)")
        }

        let codeChar = line[line.index(line.startIndex, offsetBy: 1)]
        guard let code = PropCode(rawValue: codeChar) else {
            throw WinlinkError.malformedInput("Unsupported proposal code '\(codeChar)'")
        }
        self.code = code

        switch code {
        case .basic, .ascii:
            // Go leaves these unparsed (TODO there as well); the session
            // defers them since only B2 formats are supported.
            return
        case .wl2k, .gzip:
            break
        }

        guard line.count >= 4 else {
            throw WinlinkError.malformedInput("Unexpected end of proposal line")
        }

        // FC EM TJKYEIMMHSRB 527 123 0
        let parts = line.dropFirst(3).split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count >= 5 else {
            throw WinlinkError.malformedInput("Malformed proposal: \(line.dropFirst(2))")
        }
        guard parts.count <= 5 else {
            throw WinlinkError.malformedInput("Too many parts in proposal: \(parts)")
        }

        guard (1...2).contains(parts[0].count) else {
            throw WinlinkError.malformedInput("Malformed proposal 0")
        }
        guard parts[0] == "EM" || parts[0] == "CM" else {
            throw WinlinkError.malformedInput(
                "Expected message type CM or EM, but found \(parts[0])")
        }
        msgType = String(parts[0])
        mid = String(parts[1])
        size = Int(parts[2]) ?? 0
        compressedSize = Int(parts[3]) ?? 0
        // parts[4] is unused (always 0), same as in Go.
    }

    /// The wire line for this proposal, without the trailing CR
    /// (Go: sendOutbound's Sprintf).
    var proposalLine: String {
        "F\(code.rawValue) \(msgType) \(mid) \(size) \(compressedSize) 0"
    }

    /// The decompressed raw message bytes (Go: Data). Unlike Go we
    /// propagate decompression errors instead of panicking.
    func data() throws -> Data {
        try LZHUF.decode(Data(compressedData), b2: true)
    }

    /// Parses the decompressed data as a B2 message (Go: Message).
    public func message() throws -> B2Message {
        try B2Message(parsing: data())
    }

    /// The precedence of the message. Lower value is more important.
    /// See https://www.winlink.org/content/how_use_message_precedence_precedence
    var precedence: Int {
        switch true {
        case title.contains("//WL2K Z/"): return 0 // Flash
        case title.contains("//WL2K O/"): return 1 // Immediate
        case title.contains("//WL2K P/"): return 2 // Priority
        default: return 3 // Routine
        }
    }
}

extension B2Message {
    /// Prepares an outbound proposal for this message (Go: Message.Proposal).
    /// The message is validated first; only LZHUF (`FC`) proposals are produced.
    public func proposal() throws -> Proposal {
        try validate()
        return Proposal(mid: mid, title: subject, data: try bytes())
    }
}

// MARK: - Block helpers (Go: b2f.go, wl2k.go)

extension Proposal {
    /// Sorts proposals for outbound delivery: by precedence first, within
    /// equal precedence by ascending compressed size, then MID
    /// (Go: sortProposals — a size sort followed by a stable precedence sort).
    static func sort(_ proposals: inout [Proposal]) {
        proposals.sort { a, b in
            if a.precedence != b.precedence {
                return a.precedence < b.precedence
            }
            if a.compressedSize != b.compressedSize {
                return a.compressedSize < b.compressedSize
            }
            return a.mid < b.mid
        }
    }

    /// The checksum sent on the `F>` prompt line: the negated 8-bit sum of
    /// all proposal-line bytes including each trailing CR (Go: sendOutbound
    /// and handleInbound compute it inline).
    static func blockChecksum<S: Sequence<String>>(overLines lines: S) -> Int {
        var checksum = 0
        for line in lines {
            for scalar in line.unicodeScalars {
                checksum += Int(scalar.value)
            }
            checksum += Int(UInt8(ascii: "\r"))
        }
        return (-checksum) & 0xff
    }

    /// Parses a proposal answer line (`FS ...`) and applies the answers to
    /// the proposals in order (Go: parseProposalAnswer). Offset requests
    /// (`A<offset>`/`!<offset>`) are parsed; offsets beyond the protocol
    /// limit are ignored, as RMS Express is known to exceed it.
    static func applyAnswers(_ line: String, to proposals: inout [Proposal]) throws {
        var rest = Substring(line)
        if rest.hasPrefix("FS ") {
            rest = rest.dropFirst(3)
        }

        var i = 0
        while let c = rest.first {
            rest = rest.dropFirst()
            guard i < proposals.count else {
                throw WinlinkError.malformedInput("Got answer for more proposals than expected")
            }

            switch c {
            case "Y", "y", "+":
                proposals[i].answer = .accept
            case "N", "n", "R", "r", "-":
                proposals[i].answer = .reject
            case "L", "l", "=", "H", "h":
                proposals[i].answer = .defer_
            case "A", "a", "!":
                // Offset request: digits follow the answer character.
                guard let idx = rest.lastIndex(where: \.isNumber) else {
                    throw WinlinkError.malformedInput("Got offset request without offset index")
                }
                proposals[i].answer = .accept
                proposals[i].offset = Int(rest[...idx]) ?? 0
                rest = rest[rest.index(after: idx)...]

                if proposals[i].offset > ProtocolOffsetSizeLimit {
                    // RMS Express does this (in Winmor P2P for sure).
                    proposals[i].offset = 0
                }
            default:
                throw WinlinkError.malformedInput(
                    "Invalid character (\(c)) in proposal answer line")
            }
            i += 1
        }
    }
}

/// Details of a message pending download, sent by CMS v4 as `;PM:` lines
/// (Go: PendingMessage, parsePM in handshake.go).
public struct PendingMessage: Equatable, Sendable {
    public let mid: String
    public let to: Address
    public let from: Address
    public let subject: String
    public let size: Int

    /// Parses a `;PM: TO MID SIZE FROM SUBJECT` line.
    init(parsing line: String) throws {
        var str = Substring(line)
        if str.hasPrefix(";PM: ") {
            str = str.dropFirst(5)
        }
        let parts = str.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: false)
        guard parts.count == 5 else {
            throw WinlinkError.malformedInput(
                "Unexpected number of fields (\(parts.count)): \(str)")
        }
        to = Address(string: String(parts[0]))
        mid = String(parts[1])
        size = Int(parts[2]) ?? 0
        from = Address(string: String(parts[3]))
        subject = String(parts[4])
    }
}
