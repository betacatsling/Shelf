import Foundation

final class ReleaseDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destinationURL: URL
    private let onProgress: @MainActor @Sendable (Double?) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    private var downloadTask: URLSessionDownloadTask?
    private var lastReportedFraction: Double?
    private var reportedIndeterminate = false
    private var completed = false

    private init(destinationURL: URL, onProgress: @escaping @MainActor @Sendable (Double?) -> Void) {
        self.destinationURL = destinationURL
        self.onProgress = onProgress
    }

    static func download(
        from url: URL,
        to destinationURL: URL,
        userAgent: String,
        onProgress: @escaping @MainActor @Sendable (Double?) -> Void
    ) async throws {
        let delegate = ReleaseDownloadDelegate(destinationURL: destinationURL, onProgress: onProgress)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.start(url: url, userAgent: userAgent, continuation: continuation)
            }
        } onCancel: {
            delegate.cancel()
        }
    }

    private func start(url: URL, userAgent: String, continuation: CheckedContinuation<Void, Error>) {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600

        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let task = session.downloadTask(with: request)
        lock.lock()
        if completed {
            lock.unlock()
            task.cancel()
            session.invalidateAndCancel()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        self.session = session
        self.downloadTask = task
        lock.unlock()

        task.resume()
    }

    private func cancel() {
        lock.lock()
        let task = downloadTask
        let continuation = self.continuation
        let session = self.session
        let alreadyCompleted = completed
        completed = true
        self.continuation = nil
        self.downloadTask = nil
        self.session = nil
        lock.unlock()

        task?.cancel()
        session?.invalidateAndCancel()
        if !alreadyCompleted {
            continuation?.resume(throwing: CancellationError())
        }
    }

    private func finish(with result: Result<Void, Error>) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let continuation = self.continuation
        let session = self.session
        self.continuation = nil
        self.downloadTask = nil
        self.session = nil
        lock.unlock()

        session?.finishTasksAndInvalidate()
        continuation?.resume(with: result)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        if totalBytesExpectedToWrite > 0 {
            let fraction = min(max(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 0), 1)
            let shouldReport: Bool
            lock.lock()
            if completed {
                shouldReport = false
            } else if let last = lastReportedFraction {
                shouldReport = abs(fraction - last) >= 0.01 || fraction >= 1.0
            } else {
                shouldReport = true
            }
            if shouldReport {
                lastReportedFraction = fraction
            }
            lock.unlock()

            if shouldReport {
                let callback = onProgress
                Task { @MainActor in
                    callback(fraction)
                }
            }
        } else {
            let shouldReport: Bool
            lock.lock()
            if !completed && !reportedIndeterminate {
                reportedIndeterminate = true
                shouldReport = true
            } else {
                shouldReport = false
            }
            lock.unlock()

            if shouldReport {
                let callback = onProgress
                Task { @MainActor in
                    callback(nil)
                }
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode)
        {
            finish(with: .failure(UpdaterError.downloadFailed(statusCode: http.statusCode)))
            return
        }

        do {
            let parent = destinationURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destinationURL)
            try FileManager.default.moveItem(at: location, to: destinationURL)
            finish(with: .success(()))
        } catch {
            finish(with: .failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else {
            finish(with: .failure(UpdaterError.downloadFailed(statusCode: nil)))
            return
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            finish(with: .failure(CancellationError()))
        } else {
            finish(with: .failure(error))
        }
    }
}
