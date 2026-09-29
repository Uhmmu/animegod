import AnimeGodCore
import SwiftUI

/// Standing rules that download new episodes on their own.
///
/// Read and a single switch. Editing a rule stays on the Mac: the rule is read
/// off an episode set there, and there is nothing sensible to type on a phone.
struct SubscriptionsScreen: View {
    @EnvironmentObject private var model: MobileModel
    @State private var rules: [LinkSubscription] = []
    @State private var loaded = false

    var body: some View {
        List {
            ForEach(rules) { rule in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(rule.title).font(.subheadline).lineLimit(1)
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { rule.isEnabled },
                            set: { value in
                                Task {
                                    await model.setSubscriptionEnabled(id: rule.id, value)
                                    await refresh()
                                }
                            }
                        ))
                        .labelsHidden()
                    }

                    Text(rule.summary)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)

                    HStack(spacing: 8) {
                        if rule.isSeasonComplete {
                            Label("Season complete", systemImage: "checkmark.circle")
                        } else if let next = rule.nextEpisode {
                            let number = next.truncatingRemainder(dividingBy: 1) == 0
                                ? String(Int(next)) : String(format: "%.1f", next)
                            if let due = rule.estimatedNextAt {
                                Text("Episode \(number) · \(due.formatted(.relative(presentation: .named)))")
                            } else {
                                Text("Episode \(number) next")
                            }
                        }
                        if rule.waitingCount > 0 {
                            Label("\(rule.waitingCount) waiting", systemImage: "questionmark.circle")
                                .foregroundStyle(.orange)
                        }
                        Spacer()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }

            if loaded && rules.isEmpty {
                ContentUnavailableView(
                    "Nothing Followed",
                    systemImage: "bell",
                    description: Text("Seasons you follow on your Mac show up here. Anything waiting to be confirmed has to be settled there.")
                )
                .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Subscriptions")
        .refreshable { await refresh() }
        .task {
            await refresh()
            loaded = true
        }
    }

    private func refresh() async {
        if let items = await model.subscriptions() { rules = items }
    }
}
