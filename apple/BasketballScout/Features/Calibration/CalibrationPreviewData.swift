import Foundation

/// Sample data for the calibration previews, shaped like the fixtures (`calibration_put.json`,
/// `court_landmarks.json`, `game_with_calibration.json`). Nothing here touches the network.
enum CalibrationPreviewData {
    static let gameID = "g_e934f8c21058"
    /// The size of the fixture calibration's frame.
    static let frameSize = CalibrationFrameSize(width: 640, height: 360)

    /// `calibration_put.json`'s matrix: 640×360 pixels → court feet.
    static let matrix: [[Double]] = [
        [0.41190584712743544, 0.2252118572866693, -90.13488986045726],
        [-0.0001897004707451327, -0.371467589744816, 123.51761846216354],
        [-1.100905263651701e-05, 0.005359023433455877, 1.0],
    ]

    /// `calibration_put.json`: 7 points on a 640×360 frame, average error 1.486 ft.
    static var calibration: CourtCalibration {
        CourtCalibration(
            points: [
                CalibrationPoint(landmark: "left_baseline_near_corner", px: XY(x: 40, y: 330)),
                CalibrationPoint(landmark: "left_baseline_far_corner", px: XY(x: 150, y: 120)),
                CalibrationPoint(landmark: "midcourt_near", px: XY(x: 320, y: 342)),
                CalibrationPoint(landmark: "midcourt_far", px: XY(x: 320, y: 112)),
                CalibrationPoint(landmark: "right_baseline_near_corner", px: XY(x: 600, y: 330)),
                CalibrationPoint(landmark: "right_baseline_far_corner", px: XY(x: 490, y: 120)),
                CalibrationPoint(landmark: "center", px: XY(x: 321.5, y: 183.25)),
            ],
            matrix: matrix,
            reprojectionErrorFt: 1.486,
            frameT: 1.5,
            videoWidth: 640,
            videoHeight: 360,
            createdAt: ScoutTimestamp.date(from: "2026-11-11T20:02:14.709213Z"))
    }

    /// The 25 landmarks of a court, by geometry.py's formulas (04 §5.1); the NFHS court gives the values of
    /// `court_landmarks.json`.
    static func landmarks(court: CourtDimensions = .nfhs) -> CourtLandmarks {
        let length = court.lengthFt
        let width = court.widthFt
        let mid = width / 2
        let lane = court.laneWidthFt / 2
        let freeThrow = court.ftLineFromBaselineFt
        let lateral = court.threePointCornerLateralFt
        let threeTop = court.basketFromBaselineFt + court.threePointRadiusFt
        let left: [String: XY] = [
            "baseline_near_corner": XY(x: 0, y: 0),
            "baseline_far_corner": XY(x: 0, y: width),
            "lane_baseline_near": XY(x: 0, y: mid - lane),
            "lane_baseline_far": XY(x: 0, y: mid + lane),
            "ft_line_near": XY(x: freeThrow, y: mid - lane),
            "ft_line_far": XY(x: freeThrow, y: mid + lane),
            "ft_circle_top": XY(x: freeThrow + court.ftCircleRadiusFt, y: mid),
            "three_corner_near": XY(x: 0, y: mid - lateral),
            "three_corner_far": XY(x: 0, y: mid + lateral),
            "three_top": XY(x: threeTop, y: mid),
        ]
        var points: [String: XY] = [:]
        for (name, point) in left {
            points["left_" + name] = point
            points["right_" + name] = XY(x: length - point.x, y: point.y)
        }
        points["midcourt_near"] = XY(x: length / 2, y: 0)
        points["midcourt_far"] = XY(x: length / 2, y: width)
        points["center"] = XY(x: length / 2, y: mid)
        points["center_circle_near"] = XY(x: length / 2, y: mid - court.centerCircleRadiusFt)
        points["center_circle_far"] = XY(x: length / 2, y: mid + court.centerCircleRadiusFt)
        return CourtLandmarks(court: court, points: points)
    }

    /// A game shaped like `game_with_calibration.json` (uploaded film, analysed).
    static func game(
        calibration: CourtCalibration? = calibration,
        status: GameStatus = .ready,
        hasVideo: Bool = true,
        hasAnnotatedVideo: Bool = false,
        videoURL: String? = nil,
        hasTracking: Bool = true
    ) -> Game {
        Game(
            id: gameID, scoutedTeam: "Test Team A", otherTeam: "Test Team B", gameDate: GameDate("2026-11-07"),
            location: "Test Arena", level: "Varsity", scoutedColor: "dark", status: status,
            videoFilename: hasVideo ? "test-film.mp4" : nil, videoSize: hasVideo ? 41_284 : nil, videoURL: videoURL,
            hasVideo: hasVideo, hasAnnotatedVideo: hasAnnotatedVideo, hasAnalysis: hasTracking, hasTracking: hasTracking,
            calibration: calibration, latestJobID: "j_ffaf913e4144")
    }

    /// A calibration sheet's model on sample data: the drawn sample film, no server.
    static func model(game: Game = game(), landmarks: CourtLandmarks? = landmarks()) -> CalibrationModel {
        let context = GameContext.preview(game: game, landmarks: landmarks)
        return CalibrationModel(context: context, frameSources: { _, variant in
            CalibrationSampleFrameSource(variant: variant)
        })
    }
}
