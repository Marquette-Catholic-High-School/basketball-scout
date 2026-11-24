import Foundation
import Testing
@testable import BasketballScout

/// Which copy of the film plays and the fallbacks (04 §6.2; player.js:135-234).
struct PlayerVariantRulesTests {
    @Test func theAnnotatedCopyComesFirst() {
        #expect(PlayerVariantRules.initial(hasOriginal: true, hasAnnotated: true) == .annotated)
        #expect(PlayerVariantRules.initial(hasOriginal: true, hasAnnotated: false) == .original)
        #expect(PlayerVariantRules.initial(hasOriginal: false, hasAnnotated: true) == .annotated)  // a link film
        #expect(PlayerVariantRules.initial(hasOriginal: false, hasAnnotated: false) == nil)
    }

    @Test func aRequestLoadsWhatExists() {
        #expect(PlayerVariantRules.target(requested: .annotated, hasOriginal: true, hasAnnotated: true) == .annotated)
        #expect(PlayerVariantRules.target(requested: .annotated, hasOriginal: true, hasAnnotated: false) == .original)
        #expect(PlayerVariantRules.target(requested: .original, hasOriginal: false, hasAnnotated: true) == .annotated)
        #expect(PlayerVariantRules.target(requested: .original, hasOriginal: true, hasAnnotated: true) == .original)
        #expect(PlayerVariantRules.target(requested: .original, hasOriginal: false, hasAnnotated: false) == nil)
    }

    @Test func aNewAnnotatedCopyTakesOverUnlessTheCoachChose() {
        #expect(PlayerVariantRules.afterRefresh(current: .original, arrived: true, coachChose: false) == .annotated)
        #expect(PlayerVariantRules.afterRefresh(current: .original, arrived: true, coachChose: true) == nil)
        #expect(PlayerVariantRules.afterRefresh(current: .original, arrived: false, coachChose: false) == nil)
        #expect(PlayerVariantRules.afterRefresh(current: .annotated, arrived: true, coachChose: false) == nil)
    }

    @Test func failuresFallBackToTheOtherCopy() {
        #expect(PlayerVariantRules.afterFailure(.server(status: 404), failed: .annotated, hasOriginal: true, hasAnnotated: false)
            == .fallBack(to: .original, notice: PlayerText.annotatedFallback))
        #expect(PlayerVariantRules.afterFailure(.undecodable, failed: .annotated, hasOriginal: true, hasAnnotated: false)
            == .fallBack(to: .original, notice: PlayerText.annotatedFallback))
        #expect(PlayerVariantRules.afterFailure(.undecodable, failed: .original, hasOriginal: false, hasAnnotated: true)
            == .fallBack(to: .annotated, notice: PlayerText.originalUndecodableFallback))
        #expect(PlayerVariantRules.afterFailure(.server(status: 404), failed: .original, hasOriginal: false, hasAnnotated: true)
            == .fallBack(to: .annotated, notice: PlayerText.originalMissingFallback))
    }

    @Test func withNothingLeftTheCoachIsTold() {
        #expect(PlayerVariantRules.afterFailure(.undecodable, failed: .original, hasOriginal: false, hasAnnotated: false)
            == .cannotPlay(PlayerText.cannotPlay))
        #expect(PlayerVariantRules.afterFailure(.server(status: 404), failed: .original, hasOriginal: false, hasAnnotated: false)
            == .showError)
        // A connection problem would hit the other copy too: show it with "Try again" instead.
        #expect(PlayerVariantRules.afterFailure(.connection, failed: .annotated, hasOriginal: true, hasAnnotated: true) == .showError)
        #expect(PlayerVariantRules.afterFailure(.cancelled, failed: .annotated, hasOriginal: true, hasAnnotated: true) == .ignore)
    }

    @Test func theNoticesUseTheWebsWords() {
        #expect(PlayerText.annotatedFallback.message == "The annotated video isn't available, so the original film is shown.")
        #expect(PlayerText.annotatedFallback.tone == .info)
        #expect(PlayerText.cannotPlay.tone == .warning)
        #expect(PlayerText.cannotPlay.message == "The analysis is not affected.")
        #expect(PlayerText.cannotPlay.hint == "Re-export the film as H.264 MP4 to watch it here.")
    }

    // MARK: - Classifying an item's error

    @Test func loaderErrorsCarryTheirStatus() {
        let loader = NSError(domain: VideoResourceLoader.errorDomain, code: 404, userInfo: [NSLocalizedDescriptionKey: "Not found"])
        let wrapped = NSError(domain: "AVFoundationErrorDomain", code: -11_800, userInfo: [NSUnderlyingErrorKey: loader])
        #expect(PlayerFailure.classify(wrapped) == .server(status: 404))
        #expect(PlayerFailure.classify(loader) == .server(status: 404))
        #expect(PlayerFailure.underlyingError(of: wrapped, domain: VideoResourceLoader.errorDomain)?.code == 404)
    }

    @Test func transportErrorsAndCancelsAreRecognised() {
        let offline = NSError(domain: "AVFoundationErrorDomain", code: -11_800, userInfo: [
            NSUnderlyingErrorKey: URLError(.notConnectedToInternet) as NSError,
        ])
        #expect(PlayerFailure.classify(offline) == .connection)
        #expect(PlayerFailure.classify(URLError(.cancelled)) == .cancelled)
        #expect(PlayerFailure.classify(CocoaError(.userCancelled)) == .cancelled)
    }

    @Test func anythingElseIsAFilmThatCannotBeDecoded() {
        let decode = NSError(domain: "AVFoundationErrorDomain", code: -11_829, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: -12_848),
        ])
        #expect(PlayerFailure.classify(decode) == .undecodable)
        #expect(PlayerFailure.classify(nil) == .undecodable)
    }
}
