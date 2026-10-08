import Foundation

/// A plain GET over HTTPS. Injected so tests never touch the network.
protocol HTTPFetching: Sendable {
    /// The body of a `2xx` answer. Throws `HTTPError` for other statuses, oversized bodies and
    /// non-HTTPS URLs, and passes `URLError`s through (offline, timed out, …).
    func get(_ url: URL, timeout: TimeInterval, maxBytes: Int) async throws -> Data
}

enum HTTPError: Error, Equatable {
    /// Only `https://` is ever requested.
    case notHTTPS
    case status(Int)
    case tooLarge
}

/// `URLSession` with an ephemeral configuration: no cookies, no cache, no credentials stored.
/// Data arrives in chunks through a delegate, so an oversized answer is cut off at `maxBytes`
/// without being buffered twice, and a redirect to anything but `https://` is refused.
struct URLSessionHTTPClient: HTTPFetching {
    private let configuration: URLSessionConfiguration

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = UpdateLimits.requestTimeout
        configuration.timeoutIntervalForResource = UpdateLimits.downloadTimeout
        configuration.waitsForConnectivity = false
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1"
        configuration.httpAdditionalHeaders = ["User-Agent": "Dustpan/\(version) (update check)"]
        self.configuration = configuration
    }

    /// The shared settings with `timeout` as the limit for the whole transfer.
    func sessionConfiguration(timeout: TimeInterval) -> URLSessionConfiguration {
        let perRequest = configuration.copy() as? URLSessionConfiguration ?? configuration
        perRequest.timeoutIntervalForRequest = min(timeout, UpdateLimits.requestTimeout)
        perRequest.timeoutIntervalForResource = timeout
        return perRequest
    }

    func get(_ url: URL, timeout: TimeInterval, maxBytes: Int) async throws -> Data {
        guard url.scheme?.lowercased() == "https" else { throw HTTPError.notHTTPS }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        let loader = CappedLoader(maxBytes: maxBytes)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        // `timeout` bounds the whole transfer, not just the gaps between packets: 15 s for feeds and
        // lookups, 90 s only for the large cask list.
        let session = URLSession(
            configuration: sessionConfiguration(timeout: timeout), delegate: loader, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                loader.start(task, continuation: continuation)
            }
        } onCancel: {
            task.cancel()
        }
    }
}

/// Collects one data task's body. Every callback runs on the session's serial delegate queue.
private final class CappedLoader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let maxBytes: Int
    private var data = Data()
    private var failure: (any Error)?
    private var continuation: CheckedContinuation<Data, any Error>?
    private let lock = NSLock()

    init(maxBytes: Int) { self.maxBytes = maxBytes }

    func start(_ task: URLSessionDataTask, continuation: CheckedContinuation<Data, any Error>) {
        lock.withLock { self.continuation = continuation }
        task.resume()
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            failure = HTTPError.status(http.statusCode)
        } else if response.url?.scheme?.lowercased() != "https" {
            failure = HTTPError.notHTTPS
        } else if response.expectedContentLength > Int64(maxBytes) {
            failure = HTTPError.tooLarge
        } else if response.expectedContentLength > 0 {
            data.reserveCapacity(Int(response.expectedContentLength))
        }
        completionHandler(failure == nil ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard failure == nil else { return }
        data.append(chunk)
        if data.count > maxBytes {
            failure = HTTPError.tooLarge
            data = Data()
            dataTask.cancel()
        }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(request.url?.scheme?.lowercased() == "https" ? request : nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let continuation = lock.withLock {
            defer { self.continuation = nil }
            return self.continuation
        }
        if let failure {
            continuation?.resume(throwing: failure)
        } else if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume(returning: data)
            data = Data()
        }
    }
}

/// Network limits for the update check.
enum UpdateLimits {
    /// Per request (appcasts, App Store lookups).
    static let requestTimeout: TimeInterval = 15
    /// The ~19 MB Homebrew cask list.
    static let downloadTimeout: TimeInterval = 90
    /// At most this many requests at once, across all hosts.
    static let maxConcurrent = 4
    /// At most this many requests at once to one host.
    static let maxPerHost = 2
    /// Gap between two requests to the same host.
    static let hostSpacing: Duration = .milliseconds(250)
    static let appcastMaxBytes = 8 * 1_048_576
    static let lookupMaxBytes = 2 * 1_048_576
    static let caskListMaxBytes = 64 * 1_048_576
}

/// Limits how many requests run at once (overall and per host) and spaces requests to one host.
actor RequestGate {
    private let maxConcurrent: Int
    private let maxPerHost: Int
    private let spacing: Duration
    private let clock = ContinuousClock()
    private var inFlight = 0
    private var perHost: [String: Int] = [:]
    private var nextStart: [String: ContinuousClock.Instant] = [:]
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(
        maxConcurrent: Int = UpdateLimits.maxConcurrent, maxPerHost: Int = UpdateLimits.maxPerHost,
        spacing: Duration = UpdateLimits.hostSpacing
    ) {
        self.maxConcurrent = max(1, maxConcurrent)
        self.maxPerHost = max(1, maxPerHost)
        self.spacing = spacing
    }

    /// Runs `operation` once a slot for `url`'s host is free.
    func run<T: Sendable>(_ url: URL, _ operation: @Sendable () async throws -> T) async throws -> T {
        let host = url.host()?.lowercased() ?? ""
        while inFlight >= maxConcurrent || perHost[host, default: 0] >= maxPerHost {
            await withCheckedContinuation { waiters.append($0) }
        }
        inFlight += 1
        perHost[host, default: 0] += 1
        // Reserve this host's next start time before sleeping, so parallel callers queue up.
        let now = clock.now
        let start = max(now, nextStart[host] ?? now)
        nextStart[host] = start.advanced(by: spacing)
        defer { release(host) }
        if start > now { try? await clock.sleep(until: start) }
        return try await operation()
    }

    private func release(_ host: String) {
        inFlight -= 1
        perHost[host, default: 1] -= 1
        let resumed = waiters
        waiters.removeAll()
        for waiter in resumed { waiter.resume() }
    }
}

extension Error {
    /// No connection at all (as opposed to one server failing).
    var isOffline: Bool {
        guard let error = self as? URLError else { return false }
        return [
            .notConnectedToInternet, .networkConnectionLost, .internationalRoamingOff, .dataNotAllowed,
        ].contains(error.code)
    }
}

extension URL {
    /// A URL from a literal written in the code. A bad literal gives a `file:` URL, which
    /// `HTTPFetching` refuses (not HTTPS) instead of crashing.
    init(literal: StaticString) {
        self = URL(string: "\(literal)") ?? URL(fileURLWithPath: "/")
    }
}
