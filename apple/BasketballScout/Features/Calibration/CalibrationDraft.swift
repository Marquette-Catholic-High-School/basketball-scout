import Foundation

/// The points the coach is placing, as a plain value (04 §5, §6.3; calibrate.js), so every rule is testable
/// without views or a server.
///
/// - Points are kept in the pixels of `frameSize`, the copy of the film on screen. When another copy is shown
///   (the annotated one took over, or a saved calibration was measured on a different copy) everything is
///   rescaled to it (`fit(to:)`, calibrate.js `fitToVideo`).
/// - Placing a point for a landmark that already has one moves it (calibrate.js:181). The selection then
///   moves on to the next landmark without a point: first within the same end of the court, then in the
///   documented order, skipping landmarks that are the same court spot as a placed one (04 §8.17–8.18; the
///   web alternates ends, which skips back and forth for a camera that sees one end).
/// - `savedPoints`/`savedMatrix` are the saved calibration in the same pixels. The fitted court lines and the
///   fit verdict are shown only while the points are the saved ones: any change hides them until the next
///   save (calibrate.js:188-193), and undoing back to the saved points shows them again.
nonisolated struct CalibrationDraft: Hashable, Sendable {
    /// The landmarks the server offers, in the documented order (04 §5.1, `CourtLandmarks`).
    let landmarks: [CourtLandmark]
    /// The placed points, in the order they were first placed (numbered 1, 2, … on the frame).
    private(set) var points: [CalibrationPoint] = []
    /// The landmark the next click places.
    var selectedLandmark: String?
    /// The pixel grid the points are in; nil until a frame (or a saved size) is known.
    private(set) var frameSize: CalibrationFrameSize?
    /// The saved calibration's points in `frameSize` pixels ([] when nothing is saved).
    private(set) var savedPoints: [CalibrationPoint] = []
    /// The saved calibration's matrix for `frameSize` pixels.
    private(set) var savedMatrix: [[Double]]?

    private var undoStack: [Snapshot] = []
    private var moveStart: Snapshot?

    /// Court points closer than this (feet) are the same spot (04 §8.18: `*_ft_circle_top` and `*_three_top`
    /// with NFHS sizes).
    static let sameSpotTolerance = 0.01
    /// Points this close (feet) to the line through the others count as on that line.
    static let oneLineTolerance = 0.5
    /// 04 §8.19, 09 R14: encourage at least this many points.
    static let recommendedPoints = 6
    /// Undo keeps this many steps.
    static let undoLimit = 100

    private nonisolated struct Snapshot: Hashable, Sendable {
        var points: [CalibrationPoint]
        var frameSize: CalibrationFrameSize?
    }

    init(landmarks: [CourtLandmark]) {
        self.landmarks = landmarks
        selectedLandmark = landmarks.first?.name
    }

    // MARK: - Reading

    /// The fitted matrix for the points on screen: the saved one while the points are the saved ones.
    var matrix: [[Double]]? { points == savedPoints ? savedMatrix : nil }

    /// The points differ from what is saved on the server.
    var isDirty: Bool { points != savedPoints }

    /// Enough points to save (calibrate.js:203; the server needs 4, media.py:24).
    var canSave: Bool { points.count >= CalibrationRequest.minimumPoints }

    var canUndo: Bool { !undoStack.isEmpty }

    /// The count line (calibrate.js:197-199).
    var countText: String { CalibrationText.count(points.count) }

    /// The 4–5 points tip (04 §8.19), or nil.
    var tip: String? {
        (CalibrationRequest.minimumPoints..<Self.recommendedPoints).contains(points.count) ? CalibrationText.fewPointsTip : nil
    }

    /// The landmark called `name`, if the server offers it.
    func landmark(named name: String) -> CourtLandmark? {
        landmarks.first { $0.name == name }
    }

    /// The web's name of a landmark (unknown names humanized).
    func label(for name: String) -> String {
        landmark(named: name)?.label ?? Labels.landmarkLabel(for: name)
    }

    /// The point placed for `name`.
    func point(for name: String) -> CalibrationPoint? {
        points.first { $0.landmark == name }
    }

    /// The number shown next to the point for `name` (1-based), if placed.
    func number(of name: String) -> Int? {
        points.firstIndex { $0.landmark == name }.map { $0 + 1 }
    }

    /// Other landmarks that are the same court spot as `name` (04 §8.18).
    func sameSpotLandmarks(as name: String) -> [CourtLandmark] {
        guard let landmark = landmark(named: name) else { return [] }
        return landmarks.filter { $0.name != name && Self.isSameSpot($0.point, landmark.point) }
    }

    /// The first landmark without a point (documented order), skipping spots that already have one.
    var firstOpenLandmark: String? {
        openLandmarks.first?.name
    }

    /// Where the selection goes after placing `name`: the next open landmark at the same end of the court,
    /// else the first open one (04 §8.17).
    func nextLandmark(after name: String) -> String? {
        let open = openLandmarks
        let group = CourtLandmark.Group(landmarkName: name)
        return (open.first { $0.group == group } ?? open.first)?.name
    }

    private var openLandmarks: [CourtLandmark] {
        let placed = Set(points.map(\.landmark))
        let placedSpots = points.compactMap { landmark(named: $0.landmark)?.point }
        return landmarks.filter { candidate in
            !placed.contains(candidate.name) && !placedSpots.contains { Self.isSameSpot($0, candidate.point) }
        }
    }

    /// Problems with the placed points: two points on one court spot (04 §8.18), all points on one line.
    var warnings: [CalibrationWarning] {
        var result: [CalibrationWarning] = []
        let placed = points.enumerated().compactMap { index, point in
            landmark(named: point.landmark).map { (number: index + 1, landmark: $0) }
        }
        for (index, first) in placed.enumerated() {
            for second in placed[(index + 1)...] where Self.isSameSpot(first.landmark.point, second.landmark.point) {
                result.append(CalibrationWarning(
                    id: "same-spot:\(first.landmark.name):\(second.landmark.name)",
                    title: CalibrationText.sameSpotTitle,
                    message: CalibrationText.sameSpot(first.landmark.label, first.number, second.landmark.label, second.number)))
            }
        }
        if placed.count >= 3, Self.areOnOneLine(placed.map(\.landmark.point)) {
            result.append(CalibrationWarning(id: "one-line", title: CalibrationText.oneLineTitle, message: CalibrationText.oneLineMessage))
        }
        return result
    }

    /// The `PUT /api/games/{id}/calibration` body (04 §5.2, 09 D1 #11): the points in the pixels of the copy on
    /// screen (to 0.1 px), that copy's size, and the frame's time (≥ 0; nil when unknown).
    func request(frameTime: Double?) -> CalibrationRequest {
        CalibrationRequest(
            points: points.map { CalibrationPoint(landmark: $0.landmark, px: CalibrationGeometry.roundedToTenth($0.px)) },
            frameT: frameTime.flatMap { $0.isFinite ? max(0, $0) : nil },
            videoWidth: frameSize?.width,
            videoHeight: frameSize?.height)
    }

    // MARK: - Saved calibration

    /// Shows a saved calibration (or none): its points, matrix and size — `video_width/height`, else the copy
    /// on screen (calibrate.js:120-129) — rescaled to `currentSize` when known. Clears undo.
    mutating func load(_ saved: CourtCalibration?, currentSize: CalibrationFrameSize?) {
        undoStack = []
        moveStart = nil
        if let saved {
            points = saved.points
            frameSize = CalibrationFrameSize(videoWidth: saved.videoWidth, videoHeight: saved.videoHeight) ?? currentSize
        } else {
            points = []
            frameSize = currentSize ?? frameSize
        }
        setSaved(saved, currentSize: currentSize)
        if let currentSize { fit(to: currentSize) }
        selectedLandmark = firstOpenLandmark ?? landmarks.first?.name
    }

    /// Another calibration is saved now (e.g. from another device) while the coach has unsaved points: keeps
    /// the points and compares them with the new one.
    mutating func replaceSaved(_ saved: CourtCalibration?) {
        setSaved(saved, currentSize: frameSize)
    }

    private mutating func setSaved(_ saved: CourtCalibration?, currentSize: CalibrationFrameSize?) {
        guard let saved else {
            savedPoints = []
            savedMatrix = nil
            return
        }
        let measured = CalibrationFrameSize(videoWidth: saved.videoWidth, videoHeight: saved.videoHeight) ?? currentSize ?? frameSize
        var points = saved.points
        var matrix = CalibrationGeometry.isValid(saved.matrix) ? saved.matrix : nil
        if let measured, let target = frameSize, measured != target {
            points = CalibrationGeometry.rescaled(points, from: measured, to: target)
            matrix = matrix.map { CalibrationGeometry.rescaled($0, from: measured, to: target) }
        }
        savedPoints = points
        savedMatrix = matrix
    }

    /// The server saved what was sent: `sentPoints` measured in `sentSize` pixels.
    mutating func didSave(_ saved: CourtCalibration, sentPoints: [CalibrationPoint], sentSize: CalibrationFrameSize?) {
        var points = sentPoints
        var matrix = CalibrationGeometry.isValid(saved.matrix) ? saved.matrix : nil
        if let sentSize, let target = frameSize, sentSize != target {
            points = CalibrationGeometry.rescaled(points, from: sentSize, to: target)
            matrix = matrix.map { CalibrationGeometry.rescaled($0, from: sentSize, to: target) }
        }
        savedPoints = points
        savedMatrix = matrix
    }

    /// The saved calibration was removed: the points go too (calibrate.js:281-282).
    mutating func didRemoveSaved() {
        points = []
        savedPoints = []
        savedMatrix = nil
        undoStack = []
        moveStart = nil
        selectedLandmark = landmarks.first?.name
    }

    // MARK: - Copy of the film

    /// Expresses everything in the pixels of a copy of `size` (calibrate.js `fitToVideo`). The first size seen
    /// is adopted as is (a saved calibration without a size was measured on the film itself).
    mutating func fit(to size: CalibrationFrameSize) {
        guard size.isValid else { return }
        guard let from = frameSize, from.isValid, from != size else {
            frameSize = size
            return
        }
        points = CalibrationGeometry.rescaled(points, from: from, to: size)
        savedPoints = CalibrationGeometry.rescaled(savedPoints, from: from, to: size)
        savedMatrix = savedMatrix.map { CalibrationGeometry.rescaled($0, from: from, to: size) }
        frameSize = size
    }

    // MARK: - Editing

    /// Places the selected landmark at `pixel` (0.1 px), moving its earlier point if it had one, then selects
    /// the next landmark. False when nothing is selected or the pixel is not a number.
    @discardableResult
    mutating func place(at pixel: XY) -> Bool {
        guard let name = selectedLandmark, pixel.isFinite else { return false }
        let position = CalibrationGeometry.roundedToTenth(pixel)
        pushUndo()
        if let index = points.firstIndex(where: { $0.landmark == name }) {
            points[index].px = position
        } else {
            points.append(CalibrationPoint(landmark: name, px: position))
        }
        if let next = nextLandmark(after: name) { selectedLandmark = next }
        return true
    }

    /// A drag of a point starts (one undo step for the whole drag).
    mutating func beginMove() {
        if moveStart == nil { moveStart = snapshot }
    }

    /// Puts the point of `name` at `pixel` (during a drag).
    mutating func setPosition(of name: String, to pixel: XY) {
        guard pixel.isFinite, let index = points.firstIndex(where: { $0.landmark == name }) else { return }
        points[index].px = CalibrationGeometry.roundedToTenth(pixel)
    }

    /// The drag ended.
    mutating func endMove() {
        if let start = moveStart, start.points != points { push(start) }
        moveStart = nil
    }

    /// The drag was interrupted (a pinch began): the point goes back.
    mutating func cancelMove() {
        if let start = moveStart { restore(start) }
        moveStart = nil
    }

    /// Removes the point of `name` (calibrate.js:63).
    mutating func remove(_ name: String) {
        guard points.contains(where: { $0.landmark == name }) else { return }
        pushUndo()
        points.removeAll { $0.landmark == name }
    }

    /// "Clear points" (calibrate.js:58).
    mutating func clear() {
        guard !points.isEmpty else { return }
        pushUndo()
        points = []
        selectedLandmark = landmarks.first?.name
    }

    /// Goes back one change (a placed, moved, removed or cleared point).
    mutating func undo() {
        guard let last = undoStack.popLast() else { return }
        restore(last)
    }

    // MARK: - Private

    private var snapshot: Snapshot { Snapshot(points: points, frameSize: frameSize) }

    private mutating func pushUndo() {
        push(snapshot)
    }

    private mutating func push(_ snapshot: Snapshot) {
        undoStack.append(snapshot)
        if undoStack.count > Self.undoLimit { undoStack.removeFirst(undoStack.count - Self.undoLimit) }
    }

    private mutating func restore(_ snapshot: Snapshot) {
        if let from = snapshot.frameSize, let to = frameSize, from != to {
            points = CalibrationGeometry.rescaled(snapshot.points, from: from, to: to)
        } else {
            points = snapshot.points
        }
    }

    static func isSameSpot(_ a: XY, _ b: XY) -> Bool {
        a.isFinite && b.isFinite && hypot(a.x - b.x, a.y - b.y) <= sameSpotTolerance
    }

    /// All court points lie on one straight line (or on one spot): the server cannot fit a mapping from them.
    static func areOnOneLine(_ spots: [XY]) -> Bool {
        let finite = spots.filter(\.isFinite)
        guard finite.count >= 3 else { return false }
        var farthest = (first: finite[0], second: finite[0], distance: 0.0)
        for (index, a) in finite.enumerated() {
            for b in finite[(index + 1)...] {
                let distance = hypot(a.x - b.x, a.y - b.y)
                if distance > farthest.distance { farthest = (a, b, distance) }
            }
        }
        guard farthest.distance > oneLineTolerance else { return true }
        let (a, b) = (farthest.first, farthest.second)
        return finite.allSatisfy { p in
            abs((b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)) / farthest.distance <= oneLineTolerance
        }
    }
}
