// gateway/proximity against fixtures — never against the live service.
//
// The fixtures are modelled on the documented DTOs. Once the `gateways`
// CLI command has pulled a real answer, replace them with that dump:
// only then do we know what `Baud` actually carries and whether the
// service returns one row per channel or one per station.
import Foundation
import Testing

@testable import WinlinkKit

/// Records what the client sent, so tests can assert on the request
/// without a live service — same idea as `FakeRigctld`.
private actor RequestRecorder {
    private(set) var requests = [HTTPRequest]()

    func record(_ request: HTTPRequest) {
        requests.append(request)
    }

    var count: Int { requests.count }

    /// The form body of request `index`, decoded into name/value pairs.
    func fields(_ index: Int = 0) -> [String: String] {
        guard requests.indices.contains(index), let body = requests[index].body else {
            return [:]
        }
        var fields = [String: String]()
        for pair in String(decoding: body, as: UTF8.self).split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            fields[String(parts[0])] = String(parts[1]).removingPercentEncoding
        }
        return fields
    }
}

@Suite struct GatewayWebServiceTests {
    private static let key = "TESTKEY-0123456789ABCDEF"

    static func fixture(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(
                forResource: "Fixtures/WebServices/\(name)", withExtension: "json"))
        return try Data(contentsOf: url)
    }

    /// A service over a canned answer. Throttling is off unless a test
    /// asks for it — the brake has its own tests.
    private func makeService(
        fixture name: String? = nil, status: Int = 200, body: Data? = nil,
        refreshInterval: Duration = .zero
    ) throws -> (GatewayWebService, RequestRecorder) {
        let payload = try body ?? (name.map { try Self.fixture($0) } ?? Data())
        let recorder = RequestRecorder()
        let config = GatewayWebService.Config(
            userAgent: "SkywaveTests",
            minimumRequestSpacing: .zero,
            minimumRefreshInterval: refreshInterval)
        let service = GatewayWebService(apiKey: Self.key, config: config) { request in
            await recorder.record(request)
            return HTTPResponse(status: status, body: payload)
        }
        return (service, recorder)
    }

    // MARK: - Request shape

    @Test func requestHitsProximityWithTheModeSpelledOut() async throws {
        let (service, recorder) = try makeService(fixture: "proximity-ardop")

        _ = try await service.proximity(
            gridSquare: "JN47PN", modes: [.ardop], maxDistanceMiles: 500)

        #expect(await recorder.count == 1)
        let request = try #require(await recorder.requests.first)
        #expect(request.url.absoluteString == "https://api.winlink.org/gateway/proximity")
        #expect(request.method == "POST")
        #expect(request.headers["Accept"] == "application/json")

        let fields = await recorder.fields()
        // The mode goes over the wire as a NAME. Sending the enum's
        // ordinal would be a coin flip: the two published sources
        // disagree on where AnyAll sits.
        #expect(fields["OperatingMode"] == "ARDOP")
        #expect(fields["GridSquare"] == "JN47pn")
        #expect(fields["ServiceCodes"] == "PUBLIC")
        #expect(fields["MaxDistance"] == "500")
        #expect(fields["HistoryHours"] == "24")
        #expect(fields["Key"] == Self.key)
    }

    @Test func oneRequestPerMode() async throws {
        let (service, recorder) = try makeService(fixture: "proximity-empty")

        _ = try await service.proximity(gridSquare: "JN47PN", modes: [.ardop, .vara])

        #expect(await recorder.count == 2)
        #expect(await recorder.fields(0)["OperatingMode"] == "ARDOP")
        #expect(await recorder.fields(1)["OperatingMode"] == "VARA")
    }

    /// The key travels in the body. It must not show up anywhere a log
    /// or an error message could pick it up.
    @Test func theKeyNeverLeavesTheBody() async throws {
        let (service, recorder) = try makeService(fixture: "proximity-ardop")

        _ = try await service.proximity(gridSquare: "JN47PN", modes: [.ardop])

        let request = try #require(await recorder.requests.first)
        #expect(!request.description.contains(Self.key))
        #expect(!request.url.absoluteString.contains(Self.key))
        #expect(request.headers.values.allSatisfy { !$0.contains(Self.key) })
    }

    // MARK: - Decoding

    @Test func channelsDecodeWithTheRequestedMode() async throws {
        let (service, _) = try makeService(fixture: "proximity-ardop")

        let positions = try await service.proximity(
            gridSquare: "JN47PN", modes: [.ardop])

        #expect(positions.count == 4)
        let first = try #require(positions.first)
        #expect(first.callsign == "HB9AK")
        #expect(first.gridSquare == "JN36PV")
        #expect(first.frequencyHz == 7_051_500)
        #expect(first.baud == "2000")
        #expect(first.distanceMiles == 104)
        #expect(first.headingDegrees == 246)
        // The mode comes from the request, not from the payload.
        #expect(positions.allSatisfy { $0.queriedMode == .ardop })
    }

    /// The wire types are not fully pinned down: wl2k-go models the same
    /// frequency as a float, and ServiceStack may emit a bare number
    /// where the metadata promises a string. Neither may drop a channel.
    @Test func looselyTypedFieldsStillDecode() async throws {
        let (service, _) = try makeService(fixture: "proximity-loose-types")

        let positions = try await service.proximity(
            gridSquare: "JN47PN", modes: [.ardop])

        #expect(positions.count == 2)
        #expect(positions[0].frequencyHz == 7_059_500)
        #expect(positions[0].baud == "1200")
        #expect(positions[0].distanceMiles == 160)
        // A record with almost every field missing survives as blanks.
        #expect(positions[1].callsign == "HB9RF")
        #expect(positions[1].frequencyHz == 0)
        #expect(positions[1].baud == "")
    }

    @Test func emptyListIsNotAnError() async throws {
        let (service, _) = try makeService(fixture: "proximity-empty")

        let positions = try await service.proximity(gridSquare: "JN47PN", modes: [.ardop])

        #expect(positions.isEmpty)
    }

    /// The raw Mode integer is carried through but never interpreted;
    /// the observed values are collected so the mapping can be
    /// confirmed later instead of guessed now.
    @Test func rawModeIsRecordedButNotTrusted() async throws {
        let (service, _) = try makeService(fixture: "proximity-ardop")

        let positions = try await service.proximity(gridSquare: "JN47PN", modes: [.ardop])

        #expect(positions.allSatisfy { $0.rawMode == 6 })
        #expect(await service.observedModeCodes() == [.ardop: [6]])
    }

    // MARK: - Errors

    @Test func populatedResponseStatusBecomesAServiceError() async throws {
        let (service, _) = try makeService(fixture: "proximity-error")

        await #expect(
            throws: WinlinkServiceError.serviceError(
                code: "Unauthorized",
                message: "Invalid or missing web service access key")
        ) {
            try await service.proximity(gridSquare: "JN47PN", modes: [.ardop])
        }
    }

    /// The live service rejects a bad key as HTTP 400 *with* a populated
    /// ResponseStatus (verified against api.winlink.org). The body is
    /// the useful part, so it must win over the bare status code.
    @Test func rejectedKeyIsReportedAsInvalidAccessKeyNotAsHTTP400() async throws {
        let (service, _) = try makeService(
            fixture: "proximity-invalid-key", status: 400)

        let error = await #expect(throws: WinlinkServiceError.self) {
            try await service.proximity(gridSquare: "JN47PN", modes: [.ardop])
        }

        #expect(
            error
                == .serviceError(
                    code: "InvalidAccessKey",
                    message: "Invalid access key for this operation"))
        // A dead key must stop the automatic refresh, not keep knocking.
        #expect(error?.isAccessDenied == true)
        // That answer echoes the submitted key back in Errors[].Meta —
        // it may never travel on inside an error.
        #expect(error?.description.contains(Self.key) == false)
    }

    @Test(arguments: [403, 429, 500, 503])
    func nonSuccessStatusesSurfaceAsHTTPStatus(_ status: Int) async throws {
        let (service, _) = try makeService(
            fixture: "proximity-empty", status: status)

        await #expect(throws: WinlinkServiceError.httpStatus(status)) {
            try await service.proximity(gridSquare: "JN47PN", modes: [.ardop])
        }
    }

    @Test func garbagePayloadIsReportedAsMalformed() async throws {
        let (service, _) = try makeService(body: Data("<html>nope</html>".utf8))

        await #expect(throws: WinlinkServiceError.self) {
            try await service.proximity(gridSquare: "JN47PN", modes: [.ardop])
        }
    }

    @Test func missingKeyIsRefusedBeforeAnyRequest() async throws {
        let recorder = RequestRecorder()
        let service = GatewayWebService(
            apiKey: "",
            config: GatewayWebService.Config(minimumRefreshInterval: .zero)
        ) { request in
            await recorder.record(request)
            return HTTPResponse(status: 200, body: Data())
        }

        await #expect(throws: WinlinkServiceError.missingAPIKey) {
            try await service.proximity(gridSquare: "JN47PN", modes: [.ardop])
        }
        #expect(await recorder.count == 0)
    }

    /// A typo in the locator must cost nothing — the token is precious.
    @Test func invalidLocatorIsRefusedBeforeAnyRequest() async throws {
        let (service, recorder) = try makeService(fixture: "proximity-empty")

        await #expect(throws: WinlinkServiceError.invalidGridSquare("JN47PNX")) {
            try await service.proximity(gridSquare: "JN47PNX", modes: [.ardop])
        }
        #expect(await recorder.count == 0)
    }

    // MARK: - Rate limit

    /// Winlink asks that these endpoints be queried sparingly, so the
    /// brake sits in the client and no caller can talk past it.
    @Test func secondRefreshWithinTheIntervalIsThrottled() async throws {
        let (service, recorder) = try makeService(
            fixture: "proximity-empty", refreshInterval: .seconds(3600))

        _ = try await service.proximity(gridSquare: "JN47PN", modes: [.ardop])

        await #expect(throws: WinlinkServiceError.self) {
            try await service.proximity(gridSquare: "JN47PN", modes: [.ardop])
        }
        #expect(await recorder.count == 1)
    }
}
