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
