import Foundation
import os

/// The Basketball Scout API, one async throwing method per route (09 §A: 45 operations on 34 paths, plus
/// the four live-game routes of docs/LIVE.md).
///
/// Route index (`G` = `/api/games/{game_id}`; success status; method):
///
/// System (`APIClient+System`)
/// - `GET /api/health/live` → 200 `HealthLive`, no credentials: `healthLive()`
/// - `HEAD /api/health/live`: never sent (the app sends no HEAD at all; 02 §1.2)
/// - `GET /api/health` → 200 `HealthStatus`: `health()`
/// - `GET /api/court/landmarks` → 200 `CourtLandmarks`: `courtLandmarks()`
/// - `GET /api/openapi.json` → 200 (developer, 02 §11 step 4): `openAPIDocument()`
///
/// Games (`APIClient+Games`)
/// - `GET /api/games` → 200 `[Game]`: `games()`
/// - `POST /api/games` → 201 `Game`: `createGame(_:)`
/// - `GET G` → 200 `Game`: `game(id:)`
/// - `PATCH G` → 200 `Game`: `updateGame(id:_:)`
/// - `DELETE G` → 204: `deleteGame(id:)`
/// - `GET G/analysis` → 200 `GameAnalysis` (1–5 MB, decoded off the main actor): `analysis(gameID:)`
///
/// Film upload and link (`APIClient+Uploads`)
/// - `POST G/uploads` → 201 `UploadSession`: `createUpload(gameID:_:)`
/// - `GET /api/uploads/{upload_id}` → 200 `UploadSession`: `upload(id:)`
/// - `PUT /api/uploads/{upload_id}/chunk?offset=N` (raw bytes) → 200 `UploadSession`:
///   `uploadChunk(uploadID:offset:data:progress:)`
/// - `POST /api/uploads/{upload_id}/complete?auto_start=` → 200 `FilmResult`: `completeUpload(id:autoStart:)`
/// - `DELETE /api/uploads/{upload_id}` → 204: `deleteUpload(id:)`
/// - `POST G/video-url?auto_start=` → 200 `FilmResult`: `setVideoURL(gameID:_:autoStart:)`
///
/// Live games (`APIClient+Live`, docs/LIVE.md)
/// - `POST G/live` → 201 (200 when already capturing) `LiveStatus`: `startLive(gameID:segmentSeconds:)`
/// - `GET G/live` → 200 `LiveStatus`: `liveStatus(gameID:)`
/// - `POST G/live/segments` → 201 (200 when known) `UploadSession`: `createLiveSegmentUpload(gameID:_:)`
/// - `POST G/live/finish` → 200 `LiveStatus`: `finishLive(gameID:)`
///
/// Video and calibration (`APIClient+Media`)
/// - `GET G/video?variant=` → 200/206 bytes (Range): `videoURL(gameID:variant:)` with `authorizedRequest(_:)`
///   for the resource loader (09 R11)
/// - `PUT G/calibration` → 200 `CourtCalibration`: `saveCalibration(gameID:_:)`
/// - `DELETE G/calibration` → 204: `deleteCalibration(gameID:)`
///
/// Jobs and reports (`APIClient+Jobs`)
/// - `POST G/jobs` → 201 `Job`: `startJob(gameID:_:)`
/// - `GET G/jobs` → 200 `[Job]` (≤ 100, newest first): `jobs(gameID:)`
/// - `GET /api/jobs/{job_id}` → 200 `Job`: `job(id:)`
/// - `POST /api/jobs/{job_id}/cancel` → 200 `Job`: `cancelJob(id:)`
/// - `POST /api/jobs/{job_id}/retry` → 200 `Job` (the new job): `retryJob(id:)`
/// - `POST G/reports` → 202 `Job`: `generateReport(gameID:_:)`
/// - `GET G/reports` → 200 `[ReportRecord]`: `reports(gameID:)`
/// - `GET /api/reports/{report_id}` → 200 `ReportRecord`: `report(id:)`
/// - `GET G/export/report.md?report_id=` → 200 text: `reportMarkdown(gameID:reportID:)`;
///   with `download=1`: `downloadReportMarkdown(gameID:reportID:)`
///
/// Rosters (`APIClient+Rosters`) and tracks (`APIClient+Tracks`)
/// - `GET G/rosters` → 200 `GameRosters`: `rosters(gameID:)`
/// - `GET G/rosters/{side}` → 200 `Roster`: `roster(gameID:side:)`
/// - `PUT G/rosters/{side}` → 200 `Roster`: `replaceRoster(gameID:side:_:)`
/// - `POST G/rosters/{side}/import` (multipart `file` + `mode`) → 200 `RosterImportResult`:
///   `importRoster(gameID:side:fileData:filename:mode:)`, `importRoster(gameID:side:fileURL:mode:)`
/// - `POST G/rosters/{side}/players` → 200 `Roster`: `addPlayer(gameID:side:_:)`
/// - `PATCH G/rosters/{side}/players/{player_id}` → 200 `Roster`: `updatePlayer(gameID:side:playerID:_:)`
/// - `DELETE G/rosters/{side}/players/{player_id}` → 200 `Roster`: `deletePlayer(gameID:side:playerID:)`
/// - `GET /api/roster-template.csv` → 200 file: `downloadRosterTemplate()`
/// - `GET G/tracks` → 200 `TrackState`: `tracks(gameID:)`
/// - `PUT G/tracks/{track_id}` → 200 `TrackOverride`: `setTrackOverride(gameID:trackID:_:)`
/// - `DELETE G/tracks/{track_id}` → 204: `deleteTrackOverride(gameID:trackID:)`
///
/// Exports (`APIClient+Exports`)
/// - `GET G/export/fastscout.txt?side=` → 200 text: `fastScoutText(gameID:side:)`;
///   with `download=1`: `downloadFastScoutText(gameID:side:)`
/// - `GET G/export/fastscout-notes?side=` → 200 `FastScoutNotes`: `fastScoutNotes(gameID:side:)`
/// - `GET G/export/fastscout.csv?side=&table=&download=1` → file: `downloadFastScoutCSV(gameID:side:table:)`
/// - `GET /api/export/fastscout/tables` → 200 `[String]`: `fastScoutTables()`
/// - `GET G/export/timeline.csv?download=1` → file: `downloadTimelineCSV(gameID:)`
/// - `GET G/export/analysis.json?download=1` → file: `downloadAnalysisJSON(gameID:)`
///
/// Request rules (02 §1.3, §10; 09 D1 #1–2, B3): `Authorization: Basic …` on every request except the
/// liveness probe; `Content-Type: application/json` on every JSON body; never `Origin`, `Referer`,
/// `Sec-Fetch-*`, `X-Forwarded-*` or a hand-made `Cookie`; never HEAD; exact paths, no trailing slash,
/// ids percent-encoded. Failures are `APIError`s (see there for the lockout gate).
nonisolated final class APIClient: Sendable {
    /// Request idle timeouts in seconds (09 R16, R27; 02 §11).
    nonisolated enum Timeout {
        /// Ordinary JSON calls.
        static let standard: TimeInterval = 60
        /// Heavy answers: the analysis (1–5 MB, read and validated by the server on every call), its export,
        /// the reports list, and upload `complete` (up to ~60 s of ffprobe on the server).
        static let heavy: TimeInterval = 120
        /// One film chunk PUT: about 60 s without progress counts as a stall (the web's watchdog).
        static let chunk: TimeInterval = 60
        /// The liveness probe before sign-in.
        static let probe: TimeInterval = 10
    }

    let address: ServerAddress
    let credentials: ServerCredentials
    let session: URLSession

    init(address: ServerAddress, credentials: ServerCredentials, session: URLSession = ScoutHTTP.shared) {
        self.address = address
        self.credentials = credentials
        self.session = session
    }

    /// `path` (e.g. `/api/games/g_1/video?variant=annotated`) on this server.
    func url(for path: String) -> URL {
        let absolutePath = path.hasPrefix("/") ? path : "/" + path
        return URL(string: address.originString + absolutePath) ?? address.origin
    }

    /// A GET for `url` with this client's `Authorization` (only when `url` is on this server), no caching,
    /// `Accept: */*`. The video resource loader adds its `Range` header (09 R11).
    func authorizedRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Timeout.standard)
        request.httpMethod = HTTPMethod.get.rawValue
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        if address.isSameOrigin(as: url), let authorization = credentials.authorizationHeaderValue {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// The URLRequest for `request`. A chunk PUT's body is passed to the upload task separately.
    func urlRequest(for request: APIRequest) -> URLRequest {
        var text = address.originString + request.path
        if let query = request.percentEncodedQuery { text += "?" + query }
        let url = URL(string: text) ?? address.origin
        var urlRequest = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: request.timeout)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.setValue(request.accept, forHTTPHeaderField: "Accept")
        if request.sendsCredentials, let authorization = credentials.authorizationHeaderValue {
            urlRequest.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        switch request.body {
        case .none:
            break
        case .json(let data):
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = data
        case .octetStream:
            urlRequest.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        case .multipart(let data, let boundary):
            urlRequest.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = data
        }
        return urlRequest
    }

    // MARK: - Performing requests

    /// Sends `request` and returns a 2xx answer; anything else is thrown as an `APIError`.
    @concurrent
    func perform(_ request: APIRequest, progress: UploadProgressHandler? = nil) async throws(APIError) -> HTTPExchange {
        if Task.isCancelled { throw .cancelled }
        let urlRequest = urlRequest(for: request)
        var data = Data()
        var response = URLResponse()
        var attempt = 0
        while true {
            attempt += 1
            // One delegate per task: it cancels the server's 401 challenge (so the request is sent once) and
            // keeps that 401 for the error below (ScoutAuthChallenge).
            let delegate = ScoutTaskDelegate(progress: progress)
            do {
                if case .octetStream(let body) = request.body {
                    (data, response) = try await session.upload(for: urlRequest, from: body, delegate: delegate)
                } else {
                    (data, response) = try await session.data(for: urlRequest, delegate: delegate)
                }
                break
            } catch {
                let failure = delegate.apiError(for: error, url: urlRequest.url)
                // 02 §12.10: uvicorn closes idle keep-alive sockets after 5 s, so a request on a reused socket
                // can die before any answer. A GET is sent once more; a mutation never (it may have arrived).
                if request.method == .get, attempt == 1, failure.urlError?.code == .networkConnectionLost, !Task.isCancelled {
                    continue
                }
                if let rejection = delegate.rejection, failure.isAuthFailure {
                    Self.logger.debug("\(request.method.rawValue, privacy: .public) \(request.route, privacy: .public) → \(rejection.status, privacy: .private) (challenge)")
                } else {
                    Self.logger.debug("\(request.method.rawValue, privacy: .public) \(request.route, privacy: .public) failed: \(failure.urlError?.code.rawValue ?? 0, privacy: .public)")
                }
                throw failure
            }
        }
        guard let http = response as? HTTPURLResponse else { throw .notJSON(status: 0) }
        let exchange = HTTPExchange(status: http.statusCode, headers: HTTPHeaders(http), data: data)
        Self.logger.debug("\(request.method.rawValue, privacy: .public) \(request.route, privacy: .public) → \(exchange.status, privacy: .private) (\(data.count, privacy: .private) bytes)")
        guard (200..<300).contains(exchange.status) else {
            let failure = APIError.from(status: exchange.status, headers: exchange.headers, body: data)
            if failure.code == ErrorCode.crossSiteRequest {
                // 02 §6.2: only a header bug of ours can cause this.
                Self.logger.error("\(request.route, privacy: .public) was refused as a cross-site request")
            }
            throw failure
        }
        return exchange
    }

    /// Sends `request` and decodes the answer as `T` (off the main actor: the analysis is 1–5 MB).
    @concurrent
    func decoded<T: Decodable & Sendable>(_ request: APIRequest, as type: T.Type) async throws(APIError) -> T {
        let exchange = try await perform(request)
        do {
            return try ScoutJSON.decoder().decode(T.self, from: exchange.data)
        } catch {
            throw APIError.from(decodingError: error, status: exchange.status)
        }
    }

    /// Sends `request` and ignores the body (204 routes).
    @concurrent
    func sendWithoutResult(_ request: APIRequest) async throws(APIError) {
        _ = try await perform(request)
    }

    /// Sends `request` and returns the body as UTF-8 text (FastScout block, report Markdown).
    @concurrent
    func text(_ request: APIRequest) async throws(APIError) -> String {
        let exchange = try await perform(request)
        guard let text = String(data: exchange.data, encoding: .utf8) else {
            throw .decoding(status: exchange.status, detail: "The text is not UTF-8.")
        }
        return text
    }

    /// Downloads `request` into a protected temporary file named from `Content-Disposition`, or
    /// `fallbackFilename` when the header is missing (09 R45).
    @concurrent
    func download(_ request: APIRequest, fallbackFilename: String) async throws(APIError) -> DownloadedFile {
        if Task.isCancelled { throw .cancelled }
        let urlRequest = urlRequest(for: request)
        let location: URL
        let response: URLResponse
        let delegate = ScoutTaskDelegate()
        do {
            (location, response) = try await session.download(for: urlRequest, delegate: delegate)
        } catch {
            throw delegate.apiError(for: error, url: urlRequest.url)
        }
        guard let http = response as? HTTPURLResponse else {
            try? FileManager.default.removeItem(at: location)
            throw .notJSON(status: 0)
        }
        let headers = HTTPHeaders(http)
        Self.logger.debug("GET \(request.route, privacy: .public) → \(http.statusCode, privacy: .private) (download)")
        guard (200..<300).contains(http.statusCode) else {
            let body = (try? Data(contentsOf: location)) ?? Data()
            try? FileManager.default.removeItem(at: location)
            throw APIError.from(status: http.statusCode, headers: headers, body: body)
        }
        let filename = ContentDisposition.filename(from: headers.contentDisposition) ?? fallbackFilename
        do {
            return try DownloadedFile.adopt(location, filename: filename, contentType: headers.contentType)
        } catch {
            try? FileManager.default.removeItem(at: location)
            throw .local(.savingFile(filename))
        }
    }

    static let logger = Logger(subsystem: "org.marquettecatholic.BasketballScout", category: "network")
}
