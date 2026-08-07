import Foundation

/// The operating modes `gateway/proximity` filters by.
///
/// Always sent as the enum *name*. The service also returns a numeric
/// `Mode` per record, but the two published sources for that enum
/// (api.winlink.org metadata and ARSFI's `WinlinkWebServices.dtos.cs`)
/// disagree on where `AnyAll` sits, so the integers are off by one
/// between them. Mistaking VARA for ARDOP would mean the wrong
/// bandwidth and the wrong dial frequency, so we never read them —
/// Pat ignores the field for the same reason.
public enum GatewayOperatingMode: String, Sendable, CaseIterable, Codable {
    case anyAll = "AnyAll"
    case packet = "Packet"
    case pactor = "Pactor"
    case winmor = "Winmor"
    case robustPacket = "RobustPacket"
    case allHF = "AllHf"
    case ardop = "ARDOP"
    case vara = "VARA"
    case varaFM = "VARAFM"
}

/// One gateway channel as `gateway/proximity` reports it.
public struct GatewayPosition: Sendable, Equatable, Codable {
    public let callsign: String
    public let gridSquare: String
    public let frequencyHz: Int
    /// Free-text speed/bandwidth field: baud for packet, and for
    /// ARDOP/VARA the modem bandwidth. Not always filled.
    public let baud: String
    public let serviceCode: String
    /// The service reports statute miles; conversion to kilometres is
    /// the client's job.
    public let distanceMiles: Int
    public let headingDegrees: Int
    /// The mode we *asked* for — the only trustworthy mode information.
    public let queriedMode: GatewayOperatingMode
    /// The service's undocumented `Mode` integer. Diagnostics only.
    public let rawMode: Int

    public init(
        callsign: String, gridSquare: String, frequencyHz: Int, baud: String,
        serviceCode: String, distanceMiles: Int, headingDegrees: Int,
        queriedMode: GatewayOperatingMode, rawMode: Int
    ) {
        self.callsign = callsign
        self.gridSquare = gridSquare
        self.frequencyHz = frequencyHz
        self.baud = baud
        self.serviceCode = serviceCode
        self.distanceMiles = distanceMiles
        self.headingDegrees = headingDegrees
        self.queriedMode = queriedMode
        self.rawMode = rawMode
    }
}

/// Client for the Winlink Web Services gateway endpoints.
///
/// Winlink asks that these endpoints be queried sparingly and reserves
/// the right to revoke the access token, so the rate limit lives here
/// rather than in the UI: nothing above this actor can call the service
/// more often than the configured interval allows.
public actor GatewayWebService {
    public struct Config: Sendable {
        public var rootURL: URL
        public var userAgent: String
        /// Minimum gap between two individual HTTP requests.
        public var minimumRequestSpacing: Duration
        /// Minimum gap between two `proximity(…)` calls, whatever the
        /// caller's reason. `.zero` disables the brake (tests).
        public var minimumRefreshInterval: Duration

        public init(
            rootURL: URL = URL(string: "https://api.winlink.org")!,
            userAgent: String = "WinlinkKit",
            minimumRequestSpacing: Duration = .seconds(2),
            minimumRefreshInterval: Duration = .seconds(3600)
        ) {
            self.rootURL = rootURL
            self.userAgent = userAgent
            self.minimumRequestSpacing = minimumRequestSpacing
            self.minimumRefreshInterval = minimumRefreshInterval
        }
    }

    private let apiKey: String
    private let config: Config
    private let fetch: HTTPFetch

    private var lastRequest: ContinuousClock.Instant?
    private var lastRefresh: ContinuousClock.Instant?
    private var modeCodes = [GatewayOperatingMode: Set<Int>]()

    public init(
        apiKey: String, config: Config = Config(),
        fetch: @escaping HTTPFetch = HTTPFetcher.urlSession()
    ) {
        self.apiKey = apiKey
        self.config = config
        self.fetch = fetch
    }

    /// Gateway channels near `gridSquare`, one request per mode.
    ///
    /// Records carry the mode they were requested with, so a caller can
    /// merge several modes without ever touching the ambiguous `Mode`
    /// integer.
    public func proximity(
        gridSquare: String,
        modes: [GatewayOperatingMode],
        serviceCodes: [String] = ["PUBLIC"],
        historyHours: Int = 24,
        maxDistanceMiles: Int = 0
    ) async throws -> [GatewayPosition] {
        guard !apiKey.isEmpty else { throw WinlinkServiceError.missingAPIKey }
        // Reject a bad locator before spending a request on it.
        let home = try Maidenhead(locator: gridSquare)

        if config.minimumRefreshInterval > .zero, let lastRefresh {
            let elapsed = ContinuousClock.now - lastRefresh
            if elapsed < config.minimumRefreshInterval {
                throw WinlinkServiceError.throttled(
                    retryAfter: config.minimumRefreshInterval - elapsed)
            }
        }
        lastRefresh = ContinuousClock.now

        var positions = [GatewayPosition]()
        for mode in modes {
            let records = try await request(
                gridSquare: home.locator, mode: mode, serviceCodes: serviceCodes,
                historyHours: historyHours, maxDistanceMiles: maxDistanceMiles)
            positions.append(contentsOf: records)
        }
        return positions
    }

    /// Which `Mode` integers each requested mode actually returned.
    ///
    /// Purely observational: once the mapping is confirmed over a few
    /// refreshes, the several per-mode requests could collapse into a
    /// single `AnyAll` one. Until then we do not guess.
    public func observedModeCodes() -> [GatewayOperatingMode: Set<Int>] {
        modeCodes
    }

    // MARK: - One request

    private func request(
        gridSquare: String, mode: GatewayOperatingMode, serviceCodes: [String],
        historyHours: Int, maxDistanceMiles: Int
    ) async throws -> [GatewayPosition] {
        await waitForRequestSlot()

        var fields = [
            ("GridSquare", gridSquare),
            ("OperatingMode", mode.rawValue),
            ("HistoryHours", String(historyHours)),
            ("MaxDistance", String(maxDistanceMiles)),
            ("Key", apiKey),
        ]
        if !serviceCodes.isEmpty {
            fields.insert(("ServiceCodes", serviceCodes.joined(separator: ",")), at: 1)
        }

        let request = HTTPRequest(
            url: config.rootURL.appendingPathComponent("gateway/proximity"),
            method: "POST",
            headers: [
                "Accept": "application/json",
                "Content-Type": "application/x-www-form-urlencoded",
                "User-Agent": config.userAgent,
            ],
            body: Data(Self.formEncoded(fields).utf8))

        let response = try await fetch(request)

        // A rejected request comes back as HTTP 400 with a populated
        // ResponseStatus ("InvalidAccessKey"), so decode before judging
        // the status code — the body says *what* went wrong.
        //
        // Only ErrorCode and Message are ever surfaced. The Errors[].Meta
        // block echoes the submitted key back at us, and that must not
        // reach a log or the UI.
        let payload = try? JSONDecoder().decode(ProximityResponse.self, from: response.body)
        if let status = payload?.responseStatus, let code = status.errorCode, !code.isEmpty {
            throw WinlinkServiceError.serviceError(
                code: code, message: status.message ?? "")
        }
        guard (200..<300).contains(response.status) else {
            throw WinlinkServiceError.httpStatus(response.status)
        }
        guard let payload else {
            throw WinlinkServiceError.malformedResponse(
                "not a GatewayProximityResponse (\(response.body.count) bytes)")
        }

        let records = payload.gatewayList ?? []
        for record in records {
            modeCodes[mode, default: []].insert(record.mode ?? -1)
        }
        return records.map { record in
            GatewayPosition(
                callsign: record.callsign ?? "",
                gridSquare: record.gridsquare ?? "",
                frequencyHz: record.frequency ?? 0,
                baud: record.baud ?? "",
                serviceCode: record.serviceCode ?? "",
                distanceMiles: record.distance ?? 0,
                headingDegrees: record.heading ?? 0,
                queriedMode: mode,
                rawMode: record.mode ?? -1)
        }
    }

    /// Keeps consecutive requests apart, so a multi-mode refresh never
    /// arrives at the service as a burst.
    private func waitForRequestSlot() async {
        guard config.minimumRequestSpacing > .zero, let lastRequest else {
            self.lastRequest = ContinuousClock.now
            return
        }
        let elapsed = ContinuousClock.now - lastRequest
        if elapsed < config.minimumRequestSpacing {
            try? await Task.sleep(for: config.minimumRequestSpacing - elapsed)
        }
        self.lastRequest = ContinuousClock.now
    }

    static func formEncoded(_ fields: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.map { name, value in
            let encoded =
                value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            return "\(name)=\(encoded)"
        }.joined(separator: "&")
    }

    // MARK: - Wire format (ServiceStack, PascalCase)

    /// Everything optional: the service omits empty fields, and a
    /// missing one must not fail the whole list.
    private struct ProximityResponse: Decodable {
        let gatewayList: [Record]?
        let responseStatus: Status?

        enum CodingKeys: String, CodingKey {
            case gatewayList = "GatewayList"
            case responseStatus = "ResponseStatus"
        }
    }

    /// Decoded leniently on purpose. The metadata declares `Baud` a
    /// string and `Frequency` an int, but wl2k-go models the same
    /// frequency as a float64, and ServiceStack happily emits a bare
    /// number for either. A type we guessed wrong must not drop the
    /// whole channel list.
    private struct Record: Decodable {
        let callsign: String?
        let gridsquare: String?
        let frequency: Int?
        let mode: Int?
        let baud: String?
        let serviceCode: String?
        let distance: Int?
        let heading: Int?

        enum CodingKeys: String, CodingKey {
            case callsign = "Callsign"
            case gridsquare = "Gridsquare"
            case frequency = "Frequency"
            case mode = "Mode"
            case baud = "Baud"
            case serviceCode = "ServiceCode"
            case distance = "Distance"
            case heading = "Heading"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            callsign = try container.decodeIfPresent(String.self, forKey: .callsign)
            gridsquare = try container.decodeIfPresent(String.self, forKey: .gridsquare)
            serviceCode = try container.decodeIfPresent(String.self, forKey: .serviceCode)
            frequency = Self.number(container, .frequency)
            mode = Self.number(container, .mode)
            distance = Self.number(container, .distance)
            heading = Self.number(container, .heading)
            baud = Self.text(container, .baud)
        }

        /// A number that may arrive as JSON number or as a string.
        private static func number(
            _ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys
        ) -> Int? {
            if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
                return Int(value.rounded())
            }
            if let text = try? container.decodeIfPresent(String.self, forKey: key) {
                return Double(text).map { Int($0.rounded()) }
            }
            return nil
        }

        /// Text that may arrive as JSON string or as a bare number.
        private static func text(
            _ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys
        ) -> String? {
            if let value = try? container.decodeIfPresent(String.self, forKey: key) {
                return value
            }
            if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
                return value == value.rounded()
                    ? String(Int(value)) : String(value)
            }
            return nil
        }
    }

    private struct Status: Decodable {
        let errorCode: String?
        let message: String?

        enum CodingKeys: String, CodingKey {
            case errorCode = "ErrorCode"
            case message = "Message"
        }
    }
}
