import Foundation

public protocol SelfUpdateTransport: Sendable {
    func fetch(
        _ url: URL,
        maximumBytes: Int,
        timeout: TimeInterval
    ) throws -> Data

    func download(
        _ url: URL,
        to destination: URL,
        maximumBytes: Int64,
        timeout: TimeInterval
    ) throws
}

public struct HTTPSUpdateTransport: SelfUpdateTransport {
    public init() {}

    public func fetch(
        _ url: URL,
        maximumBytes: Int,
        timeout: TimeInterval
    ) throws -> Data {
        guard maximumBytes > 0, timeout > 0, timeout.isFinite else {
            throw SelfUpdateError.networkFailure
        }
        try SelfUpdateURLPolicy.validate(url)
        let delegate = BoundedDataDelegate(maximumBytes: maximumBytes)
        let session = URLSession(
            configuration: sessionConfiguration(timeout: timeout),
            delegate: delegate,
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: URLRequest(url: url))
        task.resume()
        guard delegate.wait(timeout: timeout + 1) else {
            task.cancel()
            throw SelfUpdateError.timeout
        }
        return try delegate.result()
    }

    public func download(
        _ url: URL,
        to destination: URL,
        maximumBytes: Int64,
        timeout: TimeInterval
    ) throws {
        guard maximumBytes > 0, timeout > 0, timeout.isFinite else {
            throw SelfUpdateError.networkFailure
        }
        try SelfUpdateURLPolicy.validate(url)
        let delegate = BoundedDownloadDelegate(
            destination: destination,
            maximumBytes: maximumBytes
        )
        let session = URLSession(
            configuration: sessionConfiguration(timeout: timeout),
            delegate: delegate,
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: URLRequest(url: url))
        task.resume()
        guard delegate.wait(timeout: timeout + 1) else {
            task.cancel()
            throw SelfUpdateError.timeout
        }
        try delegate.result()
    }

    private func sessionConfiguration(
        timeout: TimeInterval
    ) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.httpAdditionalHeaders = [
            "Accept": "application/octet-stream, application/json",
            "User-Agent": "SparkleReleaseKit/\(SparkleReleaseKitVersion.current)",
        ]
        return configuration
    }
}

enum SelfUpdateURLPolicy {
    static func validate(
        _ url: URL,
        allowRedirectQuery: Bool = false
    ) throws {
        guard url.scheme?.lowercased() == "https",
            url.host != nil,
            url.user == nil,
            url.password == nil,
            let components = URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
            ),
            allowRedirectQuery || components.query == nil,
            components.fragment == nil
        else {
            throw SelfUpdateError.unsafeURL
        }
    }
}

private func validHTTPResponse(_ response: URLResponse?) -> Bool {
    guard let response = response as? HTTPURLResponse,
        (200...299).contains(response.statusCode),
        let finalURL = response.url,
        (try? SelfUpdateURLPolicy.validate(
            finalURL,
            allowRedirectQuery: true
        )) != nil
    else {
        return false
    }
    return true
}

private final class BoundedDataDelegate: NSObject, URLSessionDataDelegate,
    @unchecked Sendable
{
    private let maximumBytes: Int
    private let lock = NSLock()
    private let completion = DispatchSemaphore(value: 0)
    private var data = Data()
    private var response: URLResponse?
    private var failure: SelfUpdateError?
    private var completed = false

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        self.response = response
        let expected = response.expectedContentLength
        let tooLarge = expected > Int64(maximumBytes)
        if tooLarge { failure = .responseTooLarge }
        lock.unlock()
        completionHandler(tooLarge ? .cancel : .allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        lock.lock()
        if self.data.count > maximumBytes - data.count {
            failure = .responseTooLarge
            lock.unlock()
            dataTask.cancel()
            return
        }
        self.data.append(data)
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url,
            (try? SelfUpdateURLPolicy.validate(
                url,
                allowRedirectQuery: true
            )) != nil
        else {
            lock.lock()
            failure = .unsafeURL
            lock.unlock()
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        if failure == nil, let error {
            failure =
                (error as NSError).code == NSURLErrorTimedOut
                ? .timeout : .networkFailure
        }
        completed = true
        lock.unlock()
        completion.signal()
    }

    func wait(timeout: TimeInterval) -> Bool {
        completion.wait(timeout: .now() + timeout) == .success
    }

    func result() throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard completed else { throw SelfUpdateError.timeout }
        if let failure { throw failure }
        guard validHTTPResponse(response) else {
            throw SelfUpdateError.networkFailure
        }
        return data
    }
}

private final class BoundedDownloadDelegate: NSObject,
    URLSessionDownloadDelegate, @unchecked Sendable
{
    private let destination: URL
    private let maximumBytes: Int64
    private let lock = NSLock()
    private let completion = DispatchSemaphore(value: 0)
    private var response: URLResponse?
    private var failure: SelfUpdateError?
    private var completed = false
    private var moved = false

    init(destination: URL, maximumBytes: Int64) {
        self.destination = destination
        self.maximumBytes = maximumBytes
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        if totalBytesWritten > maximumBytes
            || totalBytesExpectedToWrite > maximumBytes
        {
            lock.lock()
            failure = .responseTooLarge
            lock.unlock()
            downloadTask.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        lock.lock()
        response = downloadTask.response
        let alreadyFailed = failure != nil
        lock.unlock()
        guard !alreadyFailed else { return }
        do {
            let attributes = try FileManager.default.attributesOfItem(
                atPath: location.path
            )
            let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? -1
            guard bytes >= 0, bytes <= maximumBytes else {
                throw SelfUpdateError.responseTooLarge
            }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            lock.lock()
            moved = true
            lock.unlock()
        } catch let error as SelfUpdateError {
            lock.lock()
            failure = error
            lock.unlock()
        } catch {
            lock.lock()
            failure = .networkFailure
            lock.unlock()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url,
            (try? SelfUpdateURLPolicy.validate(
                url,
                allowRedirectQuery: true
            )) != nil
        else {
            lock.lock()
            failure = .unsafeURL
            lock.unlock()
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        response = response ?? task.response
        if failure == nil, let error {
            failure =
                (error as NSError).code == NSURLErrorTimedOut
                ? .timeout : .networkFailure
        }
        completed = true
        lock.unlock()
        completion.signal()
    }

    func wait(timeout: TimeInterval) -> Bool {
        completion.wait(timeout: .now() + timeout) == .success
    }

    func result() throws {
        lock.lock()
        defer { lock.unlock() }
        guard completed else { throw SelfUpdateError.timeout }
        if let failure { throw failure }
        guard moved, validHTTPResponse(response) else {
            throw SelfUpdateError.networkFailure
        }
    }
}
