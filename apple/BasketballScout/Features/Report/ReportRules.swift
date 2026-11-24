import Foundation

/// The report tab's rules as pure functions (03 §5.1, §7.8; 09 R30, C10, B13), so they can be tested
/// without a view.
nonisolated enum ReportRules {
    // MARK: Order and selection

    /// Newest first by `created_at` (09 C10: sort by the parsed date, not the string); records without a
    /// date go last; ties keep the server's order.
    static func newestFirst(_ reports: [ReportRecord]) -> [ReportRecord] {
        reports.enumerated()
            .sorted { lhs, rhs in
                switch (lhs.element.createdAt, rhs.element.createdAt) {
                case let (left?, right?) where left != right: left > right
                case (_?, nil): true
                case (nil, _?): false
                default: lhs.offset < rhs.offset
                }
            }
            .map(\.element)
    }

    /// The report a finished REPORT job wrote (09 R30): a report job does not carry its report's id, so
    /// take the newest record with `created_at ≥ job.started_at`, else the newest.
    static func reportWritten(by job: Job, in reports: [ReportRecord]) -> ReportRecord? {
        let sorted = newestFirst(reports)
        if let started = job.startedAt,
           let written = sorted.first(where: { ($0.createdAt ?? .distantPast) >= started }) {
            return written
        }
        return sorted.first
    }

    /// The report on screen: the version the coach picked while it exists; after a report job succeeded,
    /// the report it wrote (09 R30); otherwise the newest (report.js `load`).
    static func selectedReport(in reports: [ReportRecord], pinnedID: String?, finishedJob: Job?) -> ReportRecord? {
        if let pinnedID, let pinned = reports.first(where: { $0.id == pinnedID }) { return pinned }
        if let finishedJob, finishedJob.kind == .report, finishedJob.status == .succeeded,
           let written = reportWritten(by: finishedJob, in: reports) {
            return written
        }
        return newestFirst(reports).first
    }

    /// A version picker option (report.js:96-99): "<local date-time> · <model>", plus " · with coach focus".
    static func versionTitle(
        _ record: ReportRecord,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        ScoutFormat.joined([
            ScoutFormat.dateTime(record.createdAt, locale: locale, timeZone: timeZone),
            record.model,
            ServerText.nonEmpty(record.coachFocus) == nil ? nil : ReportTexts.withCoachFocus,
        ])
    }

    /// The version picker is shown with at least one report and enabled with two or more (07 §5.4).
    static func showsVersionPicker(reportCount: Int) -> Bool { reportCount > 0 }
    static func versionPickerEnabled(reportCount: Int) -> Bool { reportCount >= 2 }

    // MARK: Generating

    /// "Generate report" without reports, else "Regenerate report" (report.js:101).
    static func generateTitle(hasReports: Bool) -> String {
        hasReports ? ReportTexts.regenerate : ReportTexts.generate
    }

    /// The status line while a report job is followed (report.js:157-163): the stage text with the usual
    /// duration; after a cancel that came too late, the "it will be kept" note; after a cancel that still
    /// stops it, just the stage text ("Cancelling…").
    static func statusLine(for job: Job) -> String {
        if !job.cancelRequested { return "\(job.stageText)\u{2026} \(ReportTexts.usualDuration)" }
        if job.isTooLateToCancel { return "\(job.stageText)\u{2026} \(ReportTexts.lateCancelNote)" }
        return job.stageText
    }

    /// The coach focus cut to the server's limit (2000 code points, as pydantic counts; 03 §1.5), never
    /// splitting a character. The web's textarea has `maxlength="2000"`.
    static func clampedFocus(_ text: String, limit: Int = ReportRequest.maximumFocusLength) -> String {
        guard text.unicodeScalars.count > limit else { return text }
        var result = ""
        var count = 0
        for character in text {
            let size = character.unicodeScalars.count
            if count + size > limit { break }
            result.append(character)
            count += size
        }
        return result
    }

    /// The focus length in code points (what the server counts).
    static func focusLength(_ text: String) -> Int { text.unicodeScalars.count }

    // MARK: The report area's message (one box at a time, 07 §5.1)

    /// What the report area shows, newest problem first: a failed start or cancel, then polling that gave
    /// up, then a list that could not be loaded, then how the last followed report job ended (unless the
    /// coach has generated again since).
    static func notice(
        actionError: (any PresentableError)?,
        trackingError: (any PresentableError)?,
        reportsError: (any PresentableError)?,
        finishedJob: Job?,
        hiddenJobID: String?
    ) -> ReportNotice? {
        if let actionError { return .actionFailed(actionError) }
        if let trackingError { return .trackingFailed(trackingError) }
        if let reportsError { return .reportsFailed(reportsError) }
        guard let job = finishedJob, job.kind == .report, job.id != hiddenJobID else { return nil }
        switch job.status {
        case .failed:
            return .jobFailed(failure(of: job))
        case .cancelled:
            return .jobCancelled
        case .succeeded where !job.warnings.isEmpty:
            return .jobFinishedWithWarnings(title: job.finishedWithWarningsTitle, warnings: job.warnings)
        default:
            return nil
        }
    }

    /// A failed report job's error: `job.error`, or the web's fallback (09 B13), which offers no "Try again".
    static func failure(of job: Job) -> ErrorInfo {
        job.error ?? ErrorInfo(
            code: ErrorCode.reportFailed,
            title: ReportTexts.failedTitle,
            message: ReportTexts.failedMessage,
            retryable: false)
    }
}

/// The one box in the report area (report.js `report-error`).
nonisolated enum ReportNotice {
    /// Starting (or cancelling) a report failed: 409 CONFLICT while an analysis runs or another report is
    /// being written, 409 ANALYSIS_NOT_READY, 503 REPORT_NOT_CONFIGURED, a network error …
    case actionFailed(any PresentableError)
    /// Following the report job gave up: offer "Check again".
    case trackingFailed(any PresentableError)
    /// `GET …/reports` failed: the list is treated as empty.
    case reportsFailed(any PresentableError)
    /// The report job failed (REPORT_RATE_LIMITED, REPORT_OVERLOADED, …): "Try again" when retryable.
    case jobFailed(any PresentableError)
    /// "Report generation was cancelled."
    case jobCancelled
    /// A too-late cancel: the report was kept, with the job's warning.
    case jobFinishedWithWarnings(title: String, warnings: [String])
}
