import SwiftUI

/// What a version brings, shown once over the whole app to people who
/// updated to it. Most updates arrive on their own, so this is the only way
/// they'd hear about them.
struct WhatsNew: Identifiable {
    struct Item: Identifiable {
        let icon: String
        let title: String
        let detail: String

        var id: String { title }
    }

    let version: String
    let items: [Item]

    var id: String { version }

    /// Every version with something to show. A version without an entry
    /// shows nothing.
    static let releases: [WhatsNew] = [
        WhatsNew(version: "1.4", items: [
            Item(icon: "alarm", title: "Repark alarm",
                 detail: "Double-parked through street cleaning? An alarm rings before it ends, even on silent, so you're back in time for a spot."),
            Item(icon: "timer", title: "As early as you like",
                 detail: "Choose how many minutes before cleaning ends to be called back. Your choice is remembered."),
            Item(icon: "bell.badge", title: "Street cleaning has started",
                 detail: "A notice when cleaning begins on your car's block, with a one-tap reminder to repark."),
            Item(icon: "square.3.layers.3d", title: "Your map, as you left it",
                 detail: "The map opens to whichever view you used last."),
        ]),
    ]

    static var currentVersion: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    /// This version's entry, if it has one.
    static var current: WhatsNew? {
        releases.first { $0.version == currentVersion }
    }
}

/// The version's highlights, in the look of the first-launch walkthrough.
struct WhatsNewView: View {
    let whatsNew: WhatsNew
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    HStack(spacing: 4) {
                        ForEach(MoveUrgency.allCases, id: \.self) { u in
                            Capsule().fill(u.color).frame(width: 24, height: 8)
                        }
                    }
                    .accessibilityHidden(true)
                    .padding(.top, 56)

                    Text("What's New")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .padding(.top, 24)
                    Text("in NYC Parking \(whatsNew.version)")
                        .font(.system(size: 17, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)

                    VStack(alignment: .leading, spacing: 26) {
                        ForEach(whatsNew.items) { item in
                            row(item)
                        }
                    }
                    .padding(.top, 40)
                    .frame(maxWidth: 420)
                }
                .padding(.horizontal, 32)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)

            Button(action: onContinue) {
                Text("Continue")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(Color.blue, in: Capsule())
            }
            .frame(maxWidth: 420)
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 12)
        }
        .background(Color(red: 0.07, green: 0.075, blue: 0.095).ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    private func row(_ item: WhatsNew.Item) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: item.icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.blue)
                .frame(width: 34)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                Text(item.detail)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    WhatsNewView(whatsNew: WhatsNew.releases[0]) { }
}
