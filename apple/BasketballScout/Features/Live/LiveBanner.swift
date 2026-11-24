import SwiftUI

/// The live banner of the game page (docs/LIVE.md), under the header while `Game.live` is not `ended`: the
/// "Live" badge with the state in words, how much film has arrived and how far the stats reach, the parts
/// analysed, parts that could not be, what the live job warns about, and "End live game" (asked first).
///
/// On the Mac the banner also holds this Mac's capture of the game (`LiveCapturePanel`), or, after the app
/// was quit in the middle of one, the offer to take it up again (`LiveResumePanel`). An ended capture keeps
/// its panel on the page until the coach dismisses it, also after the game itself has ended.
struct LiveBanner: View {
    @Environment(GameContext.self) private var context
    @Environment(GameDetailModel.self) private var model
    #if os(macOS)
    @Environment(LiveCaptureCenter.self) private var captures: LiveCaptureCenter?
    @State private var leftovers = LiveLeftovers()
    #endif

    var body: some View {
        Group {
            if let state = model.liveBanner {
                Card(title: LiveText.bannerTitle) {
                    LiveBannerFacts(state: state, spokenFacts: spokenFacts)
                    if !model.liveWarnings.isEmpty {
                        NoticeView(tone: .warning, title: LiveText.warningsTitle, bullets: model.liveWarnings)
                    }
                    #if os(macOS)
                    captureSection(isCapturing: state.canEnd)
                    #endif
                } trailing: {
                    if state.canEnd {
                        BusyButton(
                            LiveText.endButton, busyTitle: LiveText.endBusyTitle,
                            isBusy: model.isEndingLive || model.isCaptureFinishing, role: .destructive
                        ) {
                            model.requestEndLive()
                        }
                        .buttonStyle(.bordered)
                        .touchFriendlyControlSize()
                    }
                }
                .announcesChanges(of: state.stateTitle)
            } else {
                #if os(macOS)
                afterTheGame
                #endif
            }
        }
        #if os(macOS)
        .task(id: leftoversKey) {
            guard let captures else { return }
            leftovers = await captures.leftovers(for: context.gameID, stillCapturing: context.game?.live?.isCapturing ?? false)
        }
        #endif
    }

    private var spokenFacts: String {
        context.game?.live.map(LiveBannerState.spokenFacts) ?? ""
    }

    #if os(macOS)
    private var capture: LiveCaptureController? {
        captures?.controller(for: context.gameID)
    }

    /// What decides when this Mac's leftovers are looked up again.
    private var leftoversKey: String {
        "\(context.gameID)|\(context.game?.live?.state.rawValue ?? "-")|\(capture?.isActive ?? false)|\(capture != nil)"
    }

    /// Inside the banner: this Mac's capture, or the offer to resume one.
    @ViewBuilder
    private func captureSection(isCapturing: Bool) -> some View {
        if let capture, let captures {
            Divider()
            LiveCapturePanel(capture: capture) {
                captures.dismiss(gameID: context.gameID)
            }
        } else if isCapturing, !leftovers.isEmpty, let captures {
            Divider()
            LiveResumePanel(gameID: context.gameID, leftovers: leftovers, captures: captures)
        }
    }

    /// The game is not live (any more): an ended capture's last word, or parts that were never sent.
    @ViewBuilder
    private var afterTheGame: some View {
        if let capture, let captures {
            Card(title: LiveText.captureTitle) {
                LiveCapturePanel(capture: capture, showsTitle: false) {
                    captures.dismiss(gameID: context.gameID)
                }
            }
        } else if context.game?.live != nil, leftovers.pendingParts > 0 {
            NoticeView(
                tone: .warning, title: LiveText.leftoverParts(leftovers.pendingParts),
                hint: leftovers.folder?.path(percentEncoded: false),
                actions: leftovers.folder.map { folder in
                    [NoticeAction(LiveText.showInFinder) { LiveCapturePanel.showInFinder(folder) }]
                } ?? [])
        }
    }
    #endif
}

/// The banner's own content: the state, the numbers and the notes about parts without stats.
struct LiveBannerFacts: View {
    let state: LiveBannerState
    /// The numbers as one sentence for VoiceOver.
    let spokenFacts: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
                GameDetailFlowLayout(spacing: Theme.Spacing.small, lineSpacing: Theme.Spacing.xSmall) {
                    StatusBadge(text: Game.liveBadgeText, tone: .danger, systemImage: Game.liveBadgeImage)
                    Text(verbatim: state.stateTitle)
                        .font(Theme.Typography.subsectionTitle)
                }
                if let detail = state.stateDetail {
                    Text(verbatim: detail)
                        .font(Theme.Typography.hint)
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            LiveFactRow(facts: state.facts)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: spokenFacts))
            if let failed = state.failedNote {
                Label {
                    Text(verbatim: ServerText.sentences([failed, LiveText.partsFailedHint]))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: ScoutTone.warning.systemImage)
                        .foregroundStyle(ScoutTone.warning.foreground)
                }
                .font(Theme.Typography.hint)
            }
            if let empty = state.emptyNote {
                Text(verbatim: empty)
                    .font(Theme.Typography.hint)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A row of numbers with their labels ("Film received" over "14:02"), wrapping on narrow screens.
struct LiveFactRow: View {
    let facts: [LiveBannerState.Fact]

    var body: some View {
        GameDetailFlowLayout(spacing: Theme.Spacing.xLarge, lineSpacing: Theme.Spacing.small) {
            ForEach(facts) { fact in
                VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                    Text(verbatim: fact.label)
                        .font(Theme.Typography.hint)
                        .foregroundStyle(Theme.secondaryText)
                    Text(verbatim: fact.value)
                        .font(.title3.weight(.semibold).monospacedDigit())
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

#Preview("Live banner – states") {
    ScrollView {
        VStack(spacing: Theme.Spacing.large) {
            Card(title: LiveText.bannerTitle) {
                LiveBannerFacts(state: LiveBannerState(live: LiveInfo()), spokenFacts: "")
            }
            Card(title: LiveText.bannerTitle) {
                LiveBannerFacts(
                    state: LiveBannerState(live: LiveInfo(
                        segmentsReceived: 7, segmentsAnalysed: 4, segmentsFailed: 1, segmentsEmpty: 1,
                        receivedS: 842.1, analysedS: 601.3, analysisVersion: 5)),
                    spokenFacts: "")
            }
            Card(title: LiveText.bannerTitle) {
                LiveBannerFacts(
                    state: LiveBannerState(live: LiveInfo(
                        state: .finishing, segmentsReceived: 40, segmentsAnalysed: 38, receivedS: 4801, analysedS: 4560,
                        analysisVersion: 38)),
                    spokenFacts: "")
            }
        }
        .padding()
    }
    .scoutPageBackground()
}
