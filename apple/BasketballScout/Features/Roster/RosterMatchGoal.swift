import SwiftUI

/// The tracks card's match-rate line (roster.html `#tracks-goal`): the rate, the forecast with the unsaved
/// choices, how many of the longest unnamed tracks reach 75%, and "Show them" for the "Name these first" list.
struct RosterMatchGoal: View {
    let model: RosterPageModel

    var body: some View {
        if let projection = model.matchProjection {
            VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
                Text(verbatim: projection.text)
                    .font(Theme.Typography.hint)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if projection.canReachGoal, model.tracks.filter != .first {
                    Button("Show them") { model.setFilter(.first) }
                        .font(Theme.Typography.hint)
                        .buttonStyle(.borderless)
                }
            }
            .accessibilityElement(children: .contain)
        }
    }
}
