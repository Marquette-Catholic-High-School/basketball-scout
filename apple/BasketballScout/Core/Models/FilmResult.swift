import Foundation

/// Answer of `POST /api/uploads/{id}/complete?auto_start=` and `POST /api/games/{id}/video-url?auto_start=`
/// (01 §4.4, 03 §1.8): the game after the film change and the ANALYZE job `auto_start` queued.
///
/// `job` is null with `auto_start=false`. A repeated `complete` returns the game's latest job, which may
/// belong to an earlier film (04 §2.5): when in doubt, re-read the game.
nonisolated struct FilmResult: Codable, Hashable, Sendable {
    var game: Game
    var job: Job?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case game
        case job
    }
}
