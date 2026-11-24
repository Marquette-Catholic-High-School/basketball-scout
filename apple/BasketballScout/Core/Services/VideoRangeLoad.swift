import AVFoundation
import Foundation

/// One HTTP range request serving one AVFoundation loading request (see `VideoResourceLoader`).
///
/// URLSession calls the delegate methods on its own queue; each hops to the loader's queue, where all
/// state lives. The loader keeps the load until it ends; the load keeps the loader until its request
/// has finished, so a late callback always finds it.
nonisolated final class VideoRangeLoad: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let loadingRequest: AVAssetResourceLoadingRequest
    let range: ByteRange
    /// The HTTP request; set before it starts.
    var task: URLSessionDataTask?

    private let owner: VideoResourceLoader
    // State (on `owner.queue` only).
    private var status = 0
    private var headers = HTTPHeaders()
    /// Position in the film of the next byte the server sends.
    private var streamOffset: Int64 = 0
    private var errorBody = Data()
    private var isDone = false

    /// Error bodies are short JSON; anything longer is not read.
    private static let errorBodyLimit = 64 * 1024

    init(loadingRequest: AVAssetResourceLoadingRequest, range: ByteRange, owner: VideoResourceLoader) {
        self.loadingRequest = loadingRequest
        self.range = range
        self.owner = owner
        super.init()
    }

    // MARK: - Ending (on `owner.queue`)

    /// AVFoundation cancelled the loading request: stop the transfer, report nothing.
    func cancel() {
        guard !isDone else { return }
        isDone = true
        task?.cancel()
    }

    /// Fails the loading request with `error` without reporting it (invalidation, another request's
    /// lockout).
    func abort(with error: NSError) {
        guard !isDone else { return }
        isDone = true
        task?.cancel()
        if !loadingRequest.isFinished && !loadingRequest.isCancelled {
            loadingRequest.finishLoading(with: error)
        }
    }

    private func finish() {
        guard !isDone else { return }
        isDone = true
        task?.cancel()
        if !loadingRequest.isFinished && !loadingRequest.isCancelled {
            loadingRequest.finishLoading()
        }
        owner.loadEnded(self)
    }

    private func fail(_ error: APIError) {
        guard !isDone else { return }
        isDone = true
        task?.cancel()
        if !loadingRequest.isFinished && !loadingRequest.isCancelled {
            loadingRequest.finishLoading(with: VideoResourceLoader.nsError(for: error))
        }
        owner.loadFailed(self, error: error)
    }

    // MARK: - URLSessionDataDelegate (URLSession's queue → owner.queue)

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        let headers = http.map { HTTPHeaders($0) } ?? HTTPHeaders()
        let expectedLength = response.expectedContentLength
        owner.queue.async { self.received(status: status, headers: headers, expectedLength: expectedLength) }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        owner.queue.async { self.received(data) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        owner.queue.async { self.completed(error) }
    }

    /// The server's 401 challenge is cancelled so the request is sent once (`ScoutAuthChallenge`); its answer
    /// fails the load like any 401 (the lockout gate). The cancellation that follows finds the load done.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let disposition = ScoutAuthChallenge.disposition(for: challenge)
        if disposition == .cancelAuthenticationChallenge {
            let rejection = ScoutAuthChallenge.rejection(from: challenge)
            owner.queue.async { self.fail(rejection.apiError) }
        }
        completionHandler(disposition, nil)
    }

    // MARK: - Handling (on `owner.queue`)

    private func received(status: Int, headers: HTTPHeaders, expectedLength: Int64) {
        guard !isDone else { return }
        self.status = status
        self.headers = headers
        // Error statuses (and the 416 for a start past the end) are handled when the body is complete.
        guard (200..<300).contains(status) else { return }
        var total: Int64?
        if status == 206 {
            let contentRange = headers["Content-Range"].flatMap { ContentRange(headerValue: $0) }
            streamOffset = contentRange?.start ?? range.start
            total = contentRange?.total
        } else {
            // A 200 carries the whole film from byte 0 (a proxy that ignored Range).
            streamOffset = 0
            total = expectedLength >= 0 ? expectedLength : nil
        }
        if let total { owner.learned(contentLength: total) }
        if let information = loadingRequest.contentInformationRequest {
            let ranges = status == 206 || headers["Accept-Ranges"]?.lowercased().contains("bytes") == true
            owner.fill(information, contentLength: total, byteRangeAccess: ranges)
        }
        if loadingRequest.dataRequest == nil {
            // Only the content information was asked for.
            finish()
        }
    }

    private func received(_ data: Data) {
        guard !isDone else { return }
        guard (200..<300).contains(status) else {
            if errorBody.count < Self.errorBodyLimit {
                errorBody.append(data.prefix(Self.errorBodyLimit - errorBody.count))
            }
            return
        }
        guard let dataRequest = loadingRequest.dataRequest else { return }
        var bytes = data
        var position = streamOffset
        streamOffset += Int64(data.count)

        // Skip what AVFoundation already has (or never asked for).
        let wantedStart = dataRequest.currentOffset
        if position < wantedStart {
            let skip = Int(min(Int64(bytes.count), wantedStart - position))
            bytes = bytes.dropFirst(skip)
            position += Int64(skip)
        }
        guard bytes.isEmpty || position == wantedStart else {
            fail(.decoding(status: status, detail: "The film's bytes arrived out of order."))
            return
        }
        var wantedEnd: Int64?
        if !dataRequest.requestsAllDataToEndOfResource {
            wantedEnd = dataRequest.requestedOffset + Int64(dataRequest.requestedLength)
        }
        if let wantedEnd {
            let room = wantedEnd - position
            if room <= 0 {
                finish()
                return
            }
            if Int64(bytes.count) > room { bytes = bytes.prefix(Int(room)) }
        }
        if !bytes.isEmpty { dataRequest.respond(with: bytes) }
        if let wantedEnd, dataRequest.currentOffset >= wantedEnd {
            // Everything asked for has arrived: end the transfer early.
            finish()
        }
    }

    private func completed(_ error: (any Error)?) {
        guard !isDone else { return }
        if let error {
            let failure = APIError.from(transportError: error, url: owner.remoteURL)
            if failure.isCancellation {
                abort(with: VideoResourceLoader.cancelledError)
                owner.loadEnded(self)
            } else {
                fail(failure)
            }
            return
        }
        if status == 416 {
            // The start was past the end: there is nothing more there (Content-Range: bytes */total).
            if let total = headers["Content-Range"].flatMap({ ContentRange(headerValue: $0) })?.total {
                owner.learned(contentLength: total)
            }
            if let information = loadingRequest.contentInformationRequest {
                owner.fill(information, contentLength: nil, byteRangeAccess: true)
            }
            finish()
            return
        }
        guard (200..<300).contains(status) else {
            fail(APIError.from(status: status, headers: headers, body: errorBody))
            return
        }
        finish()
    }
}
