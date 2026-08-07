import Foundation

/// One HTTP request, reduced to what the Winlink web services need.
///
/// Deliberately a value type instead of `URLRequest`: the kit's only
/// HTTP dependency stays a single closure (`HTTPFetch`), so tests inject
/// fixtures without a `URLProtocol` stub, and nothing Foundation-mutable
/// crosses an actor boundary.
public struct HTTPRequest: Sendable, Equatable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data?

    public init(
        url: URL, method: String = "POST", headers: [String: String] = [:],
        body: Data? = nil
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
    }
}

extension HTTPRequest: CustomStringConvertible {
    /// Method and URL only. The body carries the web-service access key,
    /// so it must never reach a log or an error message.
    public var description: String { "\(method) \(url.absoluteString)" }
}

public struct HTTPResponse: Sendable, Equatable {
    public var status: Int
    public var body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

/// The single seam through which WinlinkKit speaks HTTP.
public typealias HTTPFetch = @Sendable (HTTPRequest) async throws -> HTTPResponse

public enum HTTPFetcher {
    /// The production fetch: an ephemeral `URLSession` with no disk
    /// cache and no cookie store — we talk to exactly one API and want
    /// no state that could survive the process.
    public static func urlSession(timeout: TimeInterval = 20) -> HTTPFetch {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)

        return { request in
            var urlRequest = URLRequest(url: request.url)
            urlRequest.httpMethod = request.method
            urlRequest.httpBody = request.body
            for (field, value) in request.headers {
                urlRequest.setValue(value, forHTTPHeaderField: field)
            }
            do {
                let (data, response) = try await session.data(for: urlRequest)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                return HTTPResponse(status: status, body: data)
            } catch let error as URLError {
                // `URLError.localizedDescription` never contains the body,
                // so the access key cannot leak through here.
                throw WinlinkServiceError.transport(error.localizedDescription)
            }
        }
    }
}
