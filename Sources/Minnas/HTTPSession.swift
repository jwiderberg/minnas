//
// The default URL cache at ~/Library/Caches/<bundle id>/Cache.db was found
// holding Authorization headers and full ingest bodies, so sensitive HTTP
// traffic uses an ephemeral, cache-free session. Redirects are also refused
// so a 307 can never re-POST a transcript or bearer header to another host.
//

import Foundation

private final class NoRedirectSessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

enum HTTP {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        return URLSession(
            configuration: configuration,
            delegate: NoRedirectSessionDelegate(),
            delegateQueue: nil
        )
    }()
}
