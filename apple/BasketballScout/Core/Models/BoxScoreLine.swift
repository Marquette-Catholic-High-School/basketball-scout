import Foundation

/// One box score row (01 §4.9, 06 §3.10): a player, the team line or the totals.
///
/// `reb`, `fg_pct`, `tp_pct` and `ft_pct` are computed by the server and decoded as sent; if a server ever
/// leaves one out it is computed here with the same rule (percentages 0–1, 3 decimals, nil with 0 attempts).
nonisolated struct BoxScoreLine: Codable, Hashable, Sendable {
    var player: PlayerRef
    /// Approximate on-floor video minutes (stoppages included), 1 decimal. `0.0` for a roster player never
    /// seen; null on the team and totals lines and when presence is unknown.
    var minutesEst: Double?
    var pts: Int
    var fgm: Int
    var fga: Int
    /// Three-pointers made / attempted.
    var tpm: Int
    var tpa: Int
    var ftm: Int
    var fta: Int
    var oreb: Int
    var dreb: Int
    var ast: Int
    var stl: Int
    var blk: Int
    var tov: Int
    var pf: Int
    /// Null when unknown (always null on team and totals lines).
    var plusMinus: Int?
    var zones: ZoneSplits
    /// `oreb + dreb`.
    var reb: Int
    var fgPct: Double?
    var tpPct: Double?
    var ftPct: Double?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case player
        case minutesEst = "minutes_est"
        case pts
        case fgm
        case fga
        case tpm
        case tpa
        case ftm
        case fta
        case oreb
        case dreb
        case ast
        case stl
        case blk
        case tov
        case pf
        case plusMinus = "plus_minus"
        case zones
        case reb
        case fgPct = "fg_pct"
        case tpPct = "tp_pct"
        case ftPct = "ft_pct"
    }

    init(
        player: PlayerRef,
        minutesEst: Double? = nil,
        pts: Int = 0, fgm: Int = 0, fga: Int = 0, tpm: Int = 0, tpa: Int = 0, ftm: Int = 0, fta: Int = 0,
        oreb: Int = 0, dreb: Int = 0, ast: Int = 0, stl: Int = 0, blk: Int = 0, tov: Int = 0, pf: Int = 0,
        plusMinus: Int? = nil,
        zones: ZoneSplits = ZoneSplits()
    ) {
        self.player = player
        self.minutesEst = minutesEst
        self.pts = pts
        self.fgm = fgm
        self.fga = fga
        self.tpm = tpm
        self.tpa = tpa
        self.ftm = ftm
        self.fta = fta
        self.oreb = oreb
        self.dreb = dreb
        self.ast = ast
        self.stl = stl
        self.blk = blk
        self.tov = tov
        self.pf = pf
        self.plusMinus = plusMinus
        self.zones = zones
        reb = oreb + dreb
        fgPct = ShootingSplit.percentage(made: fgm, attempts: fga)
        tpPct = ShootingSplit.percentage(made: tpm, attempts: tpa)
        ftPct = ShootingSplit.percentage(made: ftm, attempts: fta)
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        player = try container.decode(PlayerRef.self, forKey: .player)
        minutesEst = try container.decodeIfPresent(Double.self, forKey: .minutesEst)
        pts = try container.decode(Int.self, forKey: .pts)
        fgm = try container.decode(Int.self, forKey: .fgm)
        fga = try container.decode(Int.self, forKey: .fga)
        tpm = try container.decode(Int.self, forKey: .tpm)
        tpa = try container.decode(Int.self, forKey: .tpa)
        ftm = try container.decode(Int.self, forKey: .ftm)
        fta = try container.decode(Int.self, forKey: .fta)
        oreb = try container.decode(Int.self, forKey: .oreb)
        dreb = try container.decode(Int.self, forKey: .dreb)
        ast = try container.decode(Int.self, forKey: .ast)
        stl = try container.decode(Int.self, forKey: .stl)
        blk = try container.decode(Int.self, forKey: .blk)
        tov = try container.decode(Int.self, forKey: .tov)
        pf = try container.decode(Int.self, forKey: .pf)
        plusMinus = try container.decodeIfPresent(Int.self, forKey: .plusMinus)
        zones = try container.decode(ZoneSplits.self, forKey: .zones)
        reb = try container.decodeIfPresent(Int.self, forKey: .reb) ?? oreb + dreb
        fgPct = try Self.decodePercentage(container, .fgPct, made: fgm, attempts: fga)
        tpPct = try Self.decodePercentage(container, .tpPct, made: tpm, attempts: tpa)
        ftPct = try Self.decodePercentage(container, .ftPct, made: ftm, attempts: fta)
    }

    /// The sent value (null stays nil); computed only when the key is missing.
    private static func decodePercentage(
        _ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys, made: Int, attempts: Int
    ) throws -> Double? {
        guard container.contains(key) else { return ShootingSplit.percentage(made: made, attempts: attempts) }
        return try container.decodeIfPresent(Double.self, forKey: key)
    }
}
