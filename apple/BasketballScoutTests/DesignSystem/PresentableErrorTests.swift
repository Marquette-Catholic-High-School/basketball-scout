import Foundation
import Testing
@testable import BasketballScout

/// Hints are real catalogue and web texts (01 §2.4, 07 §3.8).
@Suite("PresentableError and server text")
struct PresentableErrorTests {
    private nonisolated struct MinimalError: PresentableError {
        let title = "Analysis failed"
        let message = "Building the box score / play breakdown failed."
    }

    @Test("administrator hints are technical", arguments: [
        "Start Redis (`sudo systemctl start redis-server`) or set SCOUT_QUEUE_BACKEND=sqlite.",
        "Run `modal token new` (or set MODAL_TOKEN_ID / MODAL_TOKEN_SECRET in .env) and restart the worker. For a UI demo without a GPU set SCOUT_PROCESSOR=mock.",
        "Check `journalctl -u basketball-scout-worker` and retry.",
        "On the server: sudo systemctl start basketball-scout-worker (or run python -m scout.worker). Film will wait in the queue until it runs.",
        "Check it with: sudo systemctl status basketball-scout-worker",
        "Start Redis (sudo systemctl start redis-server) or set SCOUT_QUEUE_BACKEND=sqlite in .env.",
        "Run modal token new on the server (or set MODAL_TOKEN_ID / MODAL_TOKEN_SECRET in .env), then restart the worker.",
        "Install it with: sudo apt install ffmpeg",
        "If the server runs behind nginx, raise client_max_body_size (see deploy/nginx).",
        "Make sure the deployed Modal app matches this server version (`scripts/update.sh --deploy-modal`).",
    ])
    func technicalHints(hint: String) {
        #expect(ServerText.isTechnical(hint))
    }

    @Test("coach-facing hints stay visible", arguments: [
        "Check the network connection (or that the server is running) and try again.",
        "Wait a moment and try again.",
        "Ask the server administrator if you do not have them.",
        "Retry; if it keeps happening check the server logs.",
        "Raise SCOUT_MAX_UPLOAD_GB in .env or compress/trim the film.",
        "Add ANTHROPIC_API_KEY to .env and restart the worker. Stats and exports still work.",
        "Set SCOUT_PROCESSOR=modal in .env for real analysis.",
        "Export the film as H.264 MP4 (Hudl: Download > MP4) and upload again.",
        "Click 'Re-run analysis' to rebuild it.",
        "Check the network connection; the upload resumes where it stopped.",
    ])
    func plainHints(hint: String) {
        #expect(!ServerText.isTechnical(hint))
    }

    @Test("plain and technical hints split between the box and the disclosure")
    func hintSplit() {
        let technical = DisplayError(title: "Job queue unavailable", message: "The job queue (Redis) could not be reached.",
                                     hint: "Start Redis (`sudo systemctl start redis-server`) or set SCOUT_QUEUE_BACKEND=sqlite.")
        #expect(technical.hintIsTechnical)
        #expect(technical.plainHint == nil)
        #expect(technical.technicalHint == technical.hint)

        let plain = DisplayError(title: "Server unavailable", message: "The server is not responding right now (it may be restarting).",
                                 hint: "Wait a moment and try again.", isRetryable: true)
        #expect(!plain.hintIsTechnical)
        #expect(plain.plainHint == "Wait a moment and try again.")
        #expect(plain.technicalHint == nil)

        let blank = DisplayError(title: "x", message: "y", hint: "   ")
        #expect(blank.plainHint == nil)
        #expect(blank.technicalHint == nil)
    }

    @Test("detail is disclosed unless the message already shows it")
    func disclosedDetail() {
        let validation = DisplayError(title: "Invalid input", message: "Some fields are invalid. scouted_team: Field required",
                                      detail: "scouted_team: Field required")
        #expect(validation.disclosedDetail == nil)
        let traceback = DisplayError(title: "Analysis failed", message: "Building the box score / play breakdown failed.",
                                     detail: "Traceback (most recent call last):\n  File \"pipeline.py\", line 120")
        #expect(traceback.disclosedDetail == traceback.detail)
        #expect(DisplayError(title: "x", message: "y", detail: "").disclosedDetail == nil)
    }

    @Test("protocol defaults: no hint, no detail, not retryable")
    func defaults() {
        let error = MinimalError()
        #expect(error.hint == nil)
        #expect(error.detail == nil)
        #expect(!error.isRetryable)
        #expect(error.spokenSummary == "Analysis failed. Building the box score / play breakdown failed.")
    }

    @Test("sentences joins without doubling punctuation")
    func sentences() {
        #expect(ServerText.sentences(["Error", "Can't reach the server", nil, " "]) == "Error. Can't reach the server")
        #expect(ServerText.sentences(["Which team is Riverside?", "Pick a colour."]) == "Which team is Riverside? Pick a colour.")
        #expect(ServerText.sentences([]) == "")
    }

    @Test("nonEmpty keeps text as it is")
    func nonEmpty() {
        #expect(ServerText.nonEmpty(nil) == nil)
        #expect(ServerText.nonEmpty("") == nil)
        #expect(ServerText.nonEmpty(" \n") == nil)
        #expect(ServerText.nonEmpty(" a ") == " a ")
    }

    @Test("describing: presentable errors pass through, cancellations and others are mapped")
    func describing() {
        let original = DisplayError(title: "Team name needed", message: "Enter the name of the team you are scouting.")
        let passed = DisplayError.describing(original)
        #expect(passed.title == "Team name needed")

        let cancelled = DisplayError.describing(CancellationError())
        #expect(cancelled.title == "Cancelled")
        #expect(cancelled.message == "The request was cancelled.")
        #expect(cancelled.isRetryable)
        #expect(DisplayError.describing(URLError(.cancelled)).title == "Cancelled")

        nonisolated struct Unexpected: Error {}
        let other = DisplayError.describing(Unexpected())
        #expect(other.title == "Something went wrong")
        #expect(other.isRetryable)
        #expect(other.detail?.contains("Unexpected") == true)
    }
}
