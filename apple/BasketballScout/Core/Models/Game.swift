import Foundation

/// A scouted game (01 §4.2, 03 §1.2): the answer of `GET/POST/PATCH /api/games…`, the elements of
/// `GET /api/games` (newest created first) and `FilmResult.game`. Every key is always present, except
/// `live`, which servers older than live games do not send.
///
/// Derived states the web computes (`hasFilm`, `isPlayable`, `rerunKind`, …) are in `Game+Derived.swift`;
/// labels in `Labels.swift`.
nonisolated struct Game: Codable, Hashable, Sendable, Identifiable {
    /// `g_` + 12 lowercase hex.
    var id: String
    /// `""` when unset (the web never sets it).
    var title: String
    var scoutedTeam: String
    /// `""` when unknown.
    var otherTeam: String
    var gameDate: GameDate?
    var location: String?
    /// Free text ("Varsity", "JV", …).
    var level: String?
    var notes: String?
    /// Jersey colour hint of the scouted team: `light`, `dark`, `#rrggbb` or a colour word.
    var scoutedColor: String?
    /// Pipeline team id → side, keys as sent (`{"0": "scouted", "1": "other"}`; 01 §1.2). `[:]` = automatic.
    /// Use `Int(key)` for the team id. Reset to `[:]` by new film.
    var teamIDMap: [String: TeamSide]
    var status: GameStatus
    /// Uploaded file name, or the name taken from a film link.
    var videoFilename: String?
    /// Bytes; null for link films.
    var videoSize: Int?
    /// The film link; null for uploaded film.
    var videoURL: String?
    /// A film **file** is stored on the server (false for link films).
    var hasVideo: Bool
    /// The GPU's overlay copy exists (`variant=annotated`).
    var hasAnnotatedVideo: Bool
    /// An analysis is saved. False during a Full re-analysis until the new one is saved.
    var hasAnalysis: Bool
    /// GPU results are on disk, so a REANALYZE can start. Re-read from disk on every GET.
    var hasTracking: Bool
    /// The manual court calibration; cleared by new film. There is no GET route for it (04 §1).
    var calibration: CourtCalibration?
    /// Set for a live game (docs/LIVE.md); nil for a game with an uploaded film or a link, and for a server
    /// older than live games (it sends no `live` key).
    var live: LiveInfo?
    /// Newest ANALYZE/REANALYZE/LIVE job (never a report job). Take the job panel's job from the jobs list
    /// instead: a job the queue refused is not named here (09 R33).
    var latestJobID: String?
    /// Set while the latest analysis job has failed (`status == .failed`).
    var error: ErrorInfo?
    var createdAt: Date?
    var updatedAt: Date?
    /// Server-computed: `title` if set, else "<scouted_team> vs <other_team>", else `scouted_team`.
    var displayTitle: String

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case title
        case scoutedTeam = "scouted_team"
        case otherTeam = "other_team"
        case gameDate = "game_date"
        case location
        case level
        case notes
        case scoutedColor = "scouted_color"
        case teamIDMap = "team_id_map"
        case status
        case videoFilename = "video_filename"
        case videoSize = "video_size"
        case videoURL = "video_url"
        case hasVideo = "has_video"
        case hasAnnotatedVideo = "has_annotated_video"
        case hasAnalysis = "has_analysis"
        case hasTracking = "has_tracking"
        case calibration
        case live
        case latestJobID = "latest_job_id"
        case error
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case displayTitle = "display_title"
    }

    init(
        id: String,
        title: String = "",
        scoutedTeam: String,
        otherTeam: String = "",
        gameDate: GameDate? = nil,
        location: String? = nil,
        level: String? = nil,
        notes: String? = nil,
        scoutedColor: String? = nil,
        teamIDMap: [String: TeamSide] = [:],
        status: GameStatus = .draft,
        videoFilename: String? = nil,
        videoSize: Int? = nil,
        videoURL: String? = nil,
        hasVideo: Bool = false,
        hasAnnotatedVideo: Bool = false,
        hasAnalysis: Bool = false,
        hasTracking: Bool = false,
        calibration: CourtCalibration? = nil,
        live: LiveInfo? = nil,
        latestJobID: String? = nil,
        error: ErrorInfo? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        displayTitle: String? = nil
    ) {
        self.id = id
        self.title = title
        self.scoutedTeam = scoutedTeam
        self.otherTeam = otherTeam
        self.gameDate = gameDate
        self.location = location
        self.level = level
        self.notes = notes
        self.scoutedColor = scoutedColor
        self.teamIDMap = teamIDMap
        self.status = status
        self.videoFilename = videoFilename
        self.videoSize = videoSize
        self.videoURL = videoURL
        self.hasVideo = hasVideo
        self.hasAnnotatedVideo = hasAnnotatedVideo
        self.hasAnalysis = hasAnalysis
        self.hasTracking = hasTracking
        self.calibration = calibration
        self.live = live
        self.latestJobID = latestJobID
        self.error = error
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.displayTitle = displayTitle ?? Self.displayTitle(title: title, scoutedTeam: scoutedTeam, otherTeam: otherTeam)
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        scoutedTeam = try container.decode(String.self, forKey: .scoutedTeam)
        otherTeam = try container.decode(String.self, forKey: .otherTeam)
        gameDate = try container.decodeIfPresent(GameDate.self, forKey: .gameDate)
        location = try container.decodeIfPresent(String.self, forKey: .location)
        level = try container.decodeIfPresent(String.self, forKey: .level)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        scoutedColor = try container.decodeIfPresent(String.self, forKey: .scoutedColor)
        teamIDMap = try container.decode([String: TeamSide].self, forKey: .teamIDMap)
        status = try container.decode(GameStatus.self, forKey: .status)
        videoFilename = try container.decodeIfPresent(String.self, forKey: .videoFilename)
        videoSize = try container.decodeIfPresent(Int.self, forKey: .videoSize)
        videoURL = try container.decodeIfPresent(String.self, forKey: .videoURL)
        hasVideo = try container.decode(Bool.self, forKey: .hasVideo)
        hasAnnotatedVideo = try container.decode(Bool.self, forKey: .hasAnnotatedVideo)
        hasAnalysis = try container.decode(Bool.self, forKey: .hasAnalysis)
        hasTracking = try container.decode(Bool.self, forKey: .hasTracking)
        calibration = try container.decodeIfPresent(CourtCalibration.self, forKey: .calibration)
        live = try container.decodeIfPresent(LiveInfo.self, forKey: .live)
        latestJobID = try container.decodeIfPresent(String.self, forKey: .latestJobID)
        error = try container.decodeIfPresent(ErrorInfo.self, forKey: .error)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
        // Computed by the server (01 §1.2); rebuilt with the same rule if a server ever leaves it out.
        displayTitle = try container.decodeIfPresent(String.self, forKey: .displayTitle)
            ?? Self.displayTitle(title: title, scoutedTeam: scoutedTeam, otherTeam: otherTeam)
    }

    /// The server's `display_title` rule (schemas.py:701-708).
    static func displayTitle(title: String, scoutedTeam: String, otherTeam: String) -> String {
        if !title.isEmpty { return title }
        if !otherTeam.isEmpty { return "\(scoutedTeam) vs \(otherTeam)" }
        return scoutedTeam
    }
}
