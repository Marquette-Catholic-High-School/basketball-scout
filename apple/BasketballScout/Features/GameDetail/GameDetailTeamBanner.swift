import SwiftUI

/// "Which team is <scouted_team>?" (03 §7.6, 06 §5.3; game.js:309-356): the analysis split the players by
/// jersey colour and the coach has not said which colour the scouted team wears. One button per team with its
/// colour swatch ("Navy jerseys" / "White jerseys"); a tap saves the team map and, when that changes the sides,
/// re-runs the analysis. The card's border is the scouted team's colour (app.css `.team-banner`).
struct GameDetailTeamBanner: View {
    let choices: [GameDetailTeamChoice]
    /// The game's scouted team name (`scouted_team`).
    let scoutedTeam: String
    /// The scouted team's colour on the page.
    let accent: HexColor

    @Environment(GameDetailModel.self) private var model
    @ScaledMetric(relativeTo: .body) private var swatchSize: CGFloat = 16

    var body: some View {
        Card(title: GameDetailText.teamBannerTitle(scoutedTeam: scoutedTeam)) {
            Text(verbatim: GameDetailText.teamBannerHint)
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.Spacing.small) { buttons }
                VStack(alignment: .leading, spacing: Theme.Spacing.small) { buttons }
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Theme.teamBorder(accent), lineWidth: 2)
        }
    }

    private var buttons: some View {
        ForEach(choices) { choice in
            let isSaving = model.savingTeamID == choice.teamID
            Button {
                Task { await model.chooseTeam(choice) }
            } label: {
                HStack(spacing: Theme.Spacing.small) {
                    Circle()
                        .fill(choice.swatch.color)
                        .overlay(Circle().strokeBorder(Theme.separator, lineWidth: 1))
                        .frame(width: swatchSize, height: swatchSize)
                        .accessibilityHidden(true)
                    Text(verbatim: isSaving ? GameDetailText.saving : choice.label)
                }
            }
            .buttonStyle(.bordered)
            .touchFriendlyControlSize()
            .disabled(model.isWorking)
            .accessibilityHint(Text(verbatim: "Tells the analysis that \(scoutedTeam) wears these jerseys."))
            #if os(iOS)
            .hoverEffect(.highlight)
            #endif
        }
    }
}

#Preview("GameDetail – team banner") {
    let context = GameContext.preview(
        game: GameDetailPreviewData.game(teamIDMap: [:]), analysis: GameDetailPreviewData.analysis())
    let model = GameDetailModel(context: context, toasts: nil)
    ScrollView {
        GameDetailTeamBanner(choices: model.teamChoices, scoutedTeam: "Test Team A", accent: context.teamColor(.scouted))
            .padding()
    }
    .scoutPageBackground()
    .environment(context)
    .environment(model)
}

#Preview("GameDetail – team banner, same colour words, dark, large type") {
    let teams = [
        TeamSummary(side: .scouted, name: "Test Team A", teamID: 0, colorRGB: RGB(red: 40, green: 40, blue: 48), colorName: "dark", score: 30),
        TeamSummary(side: .other, name: "Test Team B", teamID: 1, colorRGB: RGB(red: 90, green: 40, blue: 40), colorName: "dark", score: 28),
    ]
    let context = GameContext.preview(
        game: GameDetailPreviewData.game(teamIDMap: [:]), analysis: GameDetailPreviewData.analysis(teams: teams))
    let model = GameDetailModel(context: context, toasts: nil)
    ScrollView {
        GameDetailTeamBanner(choices: model.teamChoices, scoutedTeam: "Test Team A", accent: context.teamColor(.scouted))
            .padding()
    }
    .scoutPageBackground()
    .environment(context)
    .environment(model)
    .preferredColorScheme(.dark)
    .dynamicTypeSize(.accessibility2)
}
