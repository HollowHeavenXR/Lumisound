import Foundation

/// Swift face of the Rust app core (`LumisoundCore`, built by
/// scripts/build-core.sh). Everything functional lives in Rust; this file
/// only holds the shared instances and maps core errors onto the error types
/// existing Swift callers already switch on.
enum Core {
    /// One bridge client for the whole process (connection pool, HTTP/2).
    static let api = ApiClient(baseUrl: StreamingService.defaultBridgeURL)

    /// Point the client at the current bridge + session before a call.
    static func prepare(baseURL: String, token: String?) {
        if api.baseUrl() != baseURL { api.setBaseUrl(url: baseURL) }
        api.setToken(token: token)
    }

    /// URLError for transport failures, so `(error as? URLError)?.code`
    /// checks (cancellation, timeouts) keep working at call sites.
    static func urlError(_ e: CoreError) -> URLError? {
        if case let .Network(message, timedOut, cancelled) = e {
            let code: URLError.Code = cancelled ? .cancelled : (timedOut ? .timedOut : .cannotConnectToHost)
            return URLError(code, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return nil
    }
}

// MARK: - HTTP transport

extension Core {
    /// Drop-in for `URLSession.shared.data(for:)`: the request runs on the
    /// Rust core's HTTP client (shared pool, HTTP/2). Any status comes back
    /// as an HTTPURLResponse, exactly like URLSession, so callers' status
    /// handling is unchanged.
    static func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url else { throw URLError(.badURL) }
        do {
            let ex = try await httpSend(method: request.httpMethod ?? "GET", url: url.absoluteString,
                                        headers: headers(of: request), body: request.httpBody,
                                        timeoutSecs: request.timeoutInterval)
            if Task.isCancelled { throw URLError(.cancelled) }
            return (ex.body, response(ex, fallback: url))
        } catch let e as CoreError {
            if Task.isCancelled { throw URLError(.cancelled) }
            throw urlError(e) ?? URLError(.unknown, userInfo: [NSLocalizedDescriptionKey: e.localizedDescription])
        }
    }

    /// Drop-in for `URLSession.shared.upload(for:fromFile:)` (streams the file).
    static func upload(for request: URLRequest, fromFile fileURL: URL) async throws -> (Data, URLResponse) {
        guard let url = request.url else { throw URLError(.badURL) }
        do {
            let ex = try await httpUploadFile(method: request.httpMethod ?? "POST", url: url.absoluteString,
                                              headers: headers(of: request), filePath: fileURL.path,
                                              timeoutSecs: request.timeoutInterval)
            if Task.isCancelled { throw URLError(.cancelled) }
            return (ex.body, response(ex, fallback: url))
        } catch let e as CoreError {
            if Task.isCancelled { throw URLError(.cancelled) }
            throw urlError(e) ?? URLError(.unknown, userInfo: [NSLocalizedDescriptionKey: e.localizedDescription])
        }
    }

    private static func headers(of request: URLRequest) -> [HttpHeader] {
        (request.allHTTPHeaderFields ?? [:]).map { HttpHeader(name: $0.key, value: $0.value) }
    }

    private static func response(_ ex: HttpExchange, fallback: URL) -> HTTPURLResponse {
        var fields: [String: String] = [:]
        for h in ex.headers { fields[h.name] = fields[h.name].map { "\($0), \(h.value)" } ?? h.value }
        return HTTPURLResponse(url: URL(string: ex.url) ?? fallback, statusCode: Int(ex.status),
                               httpVersion: "HTTP/1.1", headerFields: fields)!
    }
}
