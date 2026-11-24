import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Loads one film for AVFoundation through the app's authenticated URLSession (09 R11, R12; DESIGN §4).
///
/// AVPlayer cannot send Basic auth, so the asset's URL uses the custom `scoutvideo` scheme and every
/// loading request comes here:
/// - content information: the UTType of the original file (`.mov` → QuickTime, else MPEG-4; the server
///   labels everything `video/mp4`), the length from `Content-Range` (or `Content-Length` on a 200),
///   byte-range access;
/// - data: one `GET /api/games/{id}/video?variant=…` per request with `Range: bytes=a-b` (or `a-` when
///   AVFoundation wants everything to the end), streamed into the request as the bytes arrive;
/// - a cancelled loading request cancels its HTTP request;
/// - failures finish the request with an error and go to `onError`. After a failure that stops every
///   request (401, 429 `AUTH_THROTTLED`) nothing more is sent (09 R6). Never HEAD (405).
///
/// AVFoundation calls the delegate methods on `queue`; all mutable state lives on it (URLSession's
/// callbacks hop over to it), which is why the class is `@unchecked Sendable`. AVFoundation holds its
/// delegate weakly: `VideoAssetFactory` ties each loader to its asset.
nonisolated final class VideoResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    /// The serial queue of every callback and every piece of state.
    let queue: DispatchQueue
    /// The server's film URL.
    let remoteURL: URL
    /// UTType identifier of the film (`public.mpeg-4` or `com.apple.quicktime-movie`).
    let contentType: String

    private let client: APIClient
    private let gate: VideoLoadGate
    private let onError: @Sendable (APIError) -> Void

    // State (on `queue` only).
    private var loads: [ObjectIdentifier: VideoRangeLoad] = [:]
    private var contentLength: Int64?
    private var isInvalidated = false

    /// - Parameters:
    ///   - onError: every failure except cancellations (called on `queue`).
    init(client: APIClient, remoteURL: URL, contentType: String, gate: VideoLoadGate, onError: @escaping @Sendable (APIError) -> Void) {
        self.client = client
        self.remoteURL = remoteURL
        self.contentType = contentType
        self.gate = gate
        self.onError = onError
        self.queue = DispatchQueue(label: "org.marquettecatholic.BasketballScout.video-loader", qos: .userInitiated)
        super.init()
    }

    /// Cancels every HTTP request and fails every pending loading request; later requests fail at once.
    func invalidate() {
        queue.async { [self] in
            isInvalidated = true
            let pending = Array(loads.values)
            loads.removeAll()
            for load in pending { load.abort(with: Self.cancelledError) }
        }
    }

    // MARK: - AVAssetResourceLoaderDelegate

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard VideoAssetFactory.isStreamURL(loadingRequest.request.url) else { return false }
        if isInvalidated || gate.isInvalidated {
            loadingRequest.finishLoading(with: Self.cancelledError)
            return true
        }
        if let stopError = gate.stopError {
            loadingRequest.finishLoading(with: Self.nsError(for: stopError))
            return true
        }

        let information = loadingRequest.contentInformationRequest
        var range: ByteRange?
        if let dataRequest = loadingRequest.dataRequest {
            range = ByteRange.remaining(
                requestedOffset: dataRequest.requestedOffset,
                requestedLength: dataRequest.requestedLength,
                currentOffset: dataRequest.currentOffset,
                toEndOfResource: dataRequest.requestsAllDataToEndOfResource,
                contentLength: contentLength)
        }
        if range == nil {
            if information == nil || contentLength != nil {
                // Nothing to fetch: no data is left to send and the length is known.
                if let information { fill(information, contentLength: contentLength, byteRangeAccess: true) }
                loadingRequest.finishLoading()
                return true
            }
            // Only the content information is wanted: two bytes tell the length (Content-Range).
            range = ByteRange(start: 0, end: 1)
        }
        if let range { start(loadingRequest, range: range) }
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        loads.removeValue(forKey: ObjectIdentifier(loadingRequest))?.cancel()
    }

    // MARK: - For VideoRangeLoad (on `queue`)

    var knownContentLength: Int64? { contentLength }

    func learned(contentLength length: Int64) {
        if length >= 0 { contentLength = length }
    }

    /// Fills AVFoundation's content information request. The type must be one of its
    /// `allowedContentTypes` (else `finishLoading` raises an exception).
    func fill(_ information: AVAssetResourceLoadingContentInformationRequest, contentLength length: Int64?, byteRangeAccess: Bool) {
        information.contentType = Self.allowedType(contentType, allowed: information.allowedContentTypes)
        if let length = length ?? contentLength { information.contentLength = length }
        information.isByteRangeAccessSupported = byteRangeAccess
        information.isEntireLengthAvailableOnDemand = true
    }

    func loadEnded(_ load: VideoRangeLoad) {
        if loads[ObjectIdentifier(load.loadingRequest)] === load {
            loads.removeValue(forKey: ObjectIdentifier(load.loadingRequest))
        }
    }

    func loadFailed(_ load: VideoRangeLoad, error: APIError) {
        loadEnded(load)
        let isFirstStop = gate.record(error)
        if error.stopsAllRequests {
            // 09 R6: one 401 or lockout stops every film request of this server; none is sent again.
            let pending = Array(loads.values)
            loads.removeAll()
            for other in pending { other.abort(with: Self.nsError(for: error)) }
            if isFirstStop { onError(error) }
        } else {
            onError(error)
        }
    }

    // MARK: - Helpers

    private func start(_ loadingRequest: AVAssetResourceLoadingRequest, range: ByteRange) {
        var request = client.authorizedRequest(remoteURL)
        request.setValue(range.headerValue, forHTTPHeaderField: "Range")
        // Byte offsets must be offsets in the file, never in a compressed body.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let load = VideoRangeLoad(loadingRequest: loadingRequest, range: range, owner: self)
        let task = client.session.dataTask(with: request)
        task.delegate = load
        load.task = task
        loads[ObjectIdentifier(loadingRequest)]?.cancel()
        loads[ObjectIdentifier(loadingRequest)] = load
        task.resume()
    }

    /// `preferred` if AVFoundation allows it (or allows anything), else the closest allowed movie type.
    static func allowedType(_ preferred: String, allowed: [String]?) -> String {
        guard let allowed, !allowed.isEmpty, !allowed.contains(preferred) else { return preferred }
        let candidates = [UTType.mpeg4Movie.identifier, UTType.quickTimeMovie.identifier, "com.apple.m4v-video"]
        return candidates.first(where: allowed.contains) ?? allowed[0]
    }

    /// The error AVFoundation gets for a failed request: the URLError itself for network failures (so
    /// AVFoundation recognises them), else the coach-facing title and message.
    static func nsError(for error: APIError) -> NSError {
        if let urlError = error.urlError { return urlError as NSError }
        return NSError(domain: errorDomain, code: error.status ?? -1, userInfo: [
            NSLocalizedDescriptionKey: error.title,
            NSLocalizedFailureReasonErrorKey: error.message,
        ])
    }

    static let errorDomain = "org.marquettecatholic.BasketballScout.video"

    static let cancelledError = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
}
