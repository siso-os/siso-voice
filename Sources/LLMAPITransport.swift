import Foundation

enum LLMAPITransport {
    // ONE long-lived session shared by all calls (data + both upload paths). URLSession
    // keep-alives the TCP/TLS connection to the provider across requests, so the 2nd+
    // transcription skips the full TLS handshake (~150-400ms saved per upload — the single
    // biggest avoidable latency in the record→paste round-trip). Previously each upload spun
    // up a fresh ephemeral session and invalidated it, paying a cold handshake EVERY time.
    // A dead keep-alive connection does NOT reliably fail fast: after sleep or a Wi-Fi /
    // Tailscale path change the pooled connection can go silently dead, and every request
    // on it (including retries, which the pool hands the same connection) hangs until the
    // timeout. Measured: zero transcription timeouts in ~5k notes before this session was
    // shared, 12 after. Retries therefore go through `uploadOnFreshConnection`.
    private static let requestSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        // `timeoutIntervalForResource` is a HARD ceiling on the entire request and
        // it silently overrides a larger per-request `timeoutInterval` (verified:
        // a request asking for 120s dies at the session cap). At 30s it capped the
        // transcription upload below its own configured timeout, so a long note on
        // a slow link was killed mid-flight and then retried from scratch twice.
        // Transcription sets its own per-request deadline; this ceiling only exists
        // to stop a truly wedged connection living forever.
        configuration.timeoutIntervalForResource = 300
        configuration.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: configuration)
    }()

    static func data(
        for request: URLRequest
    ) async throws -> (Data, URLResponse) {
        try await requestSession.data(for: request)
    }

    static func upload(
        for request: URLRequest,
        from bodyData: Data
    ) async throws -> (Data, URLResponse) {
        try await requestSession.upload(for: request, from: bodyData)
    }

    static func upload(
        for request: URLRequest,
        fromFile fileURL: URL
    ) async throws -> (Data, URLResponse) {
        try await requestSession.upload(for: request, fromFile: fileURL)
    }

    /// Upload on a throwaway session so the request cannot land on a pooled
    /// connection that has gone silently dead. Costs one TLS handshake.
    static func uploadOnFreshConnection(
        for request: URLRequest,
        fromFile fileURL: URL
    ) async throws -> (Data, URLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForResource = 300
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        return try await session.upload(for: request, fromFile: fileURL)
    }
}
