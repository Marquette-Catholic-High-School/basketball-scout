import Testing
@testable import BasketballScout

/// Confirm texts are the web's (07 §5.3); game titles are generic.
@MainActor
@Suite("ConfirmationRequest")
struct ConfirmationRequestTests {
    @Test("the first paragraph becomes the title, the rest the message")
    func splitsWebText() {
        let request = ConfirmationRequest(
            webText: "Delete \"Riverside vs Eastwood\"?\n\nThis removes the film, analysis, rosters and reports for this game. It cannot be undone.",
            confirmTitle: "Delete",
            isDestructive: true
        ) {}
        #expect(request.title == "Delete \"Riverside vs Eastwood\"?")
        #expect(request.message == "This removes the film, analysis, rosters and reports for this game. It cannot be undone.")
        #expect(request.confirmTitle == "Delete")
        #expect(request.cancelTitle == "Cancel")
        #expect(request.isDestructive)
        #expect(request.style == .alert)
    }

    @Test("later blank lines stay in the message")
    func keepsParagraphs() {
        let text = "Send the film to the GPU again?\n\nA full re-analysis takes about as long as the first run and costs another GPU run.\n\n(Re-run analysis only redoes the stats on this server.)"
        let parts = ConfirmationRequest.split(text)
        #expect(parts.title == "Send the film to the GPU again?")
        #expect(parts.message == "A full re-analysis takes about as long as the first run and costs another GPU run.\n\n(Re-run analysis only redoes the stats on this server.)")
    }

    @Test("a one-paragraph question is all title")
    func singleParagraph() {
        let parts = ConfirmationRequest.split("Stop this job? You can start it again later.")
        #expect(parts.title == "Stop this job? You can start it again later.")
        #expect(parts.message == nil)
        let trailing = ConfirmationRequest.split("Remove the saved court calibration for this game?\n\n")
        #expect(trailing.title == "Remove the saved court calibration for this game?")
        #expect(trailing.message == nil)
    }

    @Test("custom buttons and style; the action runs when called")
    func customButtons() {
        var ran = false
        let request = ConfirmationRequest(
            webText: "Cancel this upload? The part already sent will be discarded.",
            confirmTitle: "Cancel upload",
            isDestructive: true,
            cancelTitle: "Keep uploading",
            style: .dialog
        ) { ran = true }
        #expect(request.cancelTitle == "Keep uploading")
        #expect(request.style == .dialog)
        request.action()
        #expect(ran)
    }
}
