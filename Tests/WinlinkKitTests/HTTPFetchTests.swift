// The HTTP seam: value semantics and, above all, no key in any string.
import Foundation
import Testing

@testable import WinlinkKit

@Suite struct HTTPFetchTests {
    private static let key = "SUPERSECRET-ACCESS-KEY-0123456789"

    private func requestCarryingTheKey() -> HTTPRequest {
        HTTPRequest(
            url: URL(string: "https://api.winlink.org/gateway/proximity")!,
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            body: Data("GridSquare=JN47PN&Key=\(Self.key)".utf8))
    }

    @Test func requestDescriptionShowsMethodAndURLOnly() {
        let request = requestCarryingTheKey()

        #expect(request.description == "POST https://api.winlink.org/gateway/proximity")
        #expect(!request.description.contains(Self.key))
        #expect(!"\(request)".contains(Self.key))
    }

    @Test func errorDescriptionsNeverCarryTheKey() {
        let errors: [WinlinkServiceError] = [
            .missingAPIKey,
            .invalidGridSquare("nope"),
            .httpStatus(403),
            .serviceError(code: "Unauthorized", message: "Invalid key"),
            .malformedResponse("no GatewayList"),
            .transport("The Internet connection appears to be offline."),
            .throttled(retryAfter: .seconds(3600)),
        ]

        for error in errors {
            #expect(!error.description.contains(Self.key))
            #expect(!error.description.isEmpty)
        }
    }

    /// A revoked or rate-limited token must stop the automatic refresh
    /// instead of hammering on — it would hit every Skywave user.
    @Test func accessDeniedCoversTheStatusesThatMustStopRefreshing() {
        #expect(WinlinkServiceError.httpStatus(401).isAccessDenied)
        #expect(WinlinkServiceError.httpStatus(403).isAccessDenied)
        #expect(WinlinkServiceError.httpStatus(429).isAccessDenied)
        #expect(WinlinkServiceError.missingAPIKey.isAccessDenied)

        #expect(!WinlinkServiceError.httpStatus(500).isAccessDenied)
        #expect(!WinlinkServiceError.transport("offline").isAccessDenied)
        #expect(!WinlinkServiceError.throttled(retryAfter: .seconds(60)).isAccessDenied)
    }

    @Test func requestDefaultsToPOSTWithoutBody() {
        let request = HTTPRequest(url: URL(string: "https://api.winlink.org/")!)

        #expect(request.method == "POST")
        #expect(request.body == nil)
        #expect(request.headers.isEmpty)
    }

    /// The fetch closure is the only seam tests need; a stub satisfies it
    /// without any networking.
    @Test func fetchClosureIsSatisfiedByAPlainStub() async throws {
        let fetch: HTTPFetch = { request in
            #expect(request.url.path == "/gateway/proximity")
            return HTTPResponse(status: 200, body: Data(#"{"GatewayList":[]}"#.utf8))
        }

        let response = try await fetch(requestCarryingTheKey())

        #expect(response.status == 200)
        #expect(String(decoding: response.body, as: UTF8.self) == #"{"GatewayList":[]}"#)
    }
}
