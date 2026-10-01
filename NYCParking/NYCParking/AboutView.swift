import SwiftUI

/// What an app shows on its About page. Each app fills one in; `AboutView`
/// itself is the same across all of Jon Bobrow's apps, so this file can be
/// copied between them unchanged.
struct AboutApp {
    var name: String
    var icon: Image
    /// A sentence or two on what the app does.
    var description: String
    var website: URL?
    var support: URL?
    var privacy: URL?
    /// Small print at the bottom, such as where the data comes from.
    var credits: String?
}

/// The About page: icon, name, version and description, the app's own rows
/// (like "How it works"), links to its website, support and privacy policy,
/// and a link to the rest of the apps.
struct AboutView<AppRows: View>: View {
    let app: AboutApp
    @ViewBuilder var appRows: AppRows

    /// Every app links here.
    static var moreApps: URL { URL(string: "https://app.jonbobrow.com")! }

    var body: some View {
        List {
            Section {
                header
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            }

            Section {
                appRows
            }

            Section {
                if let website = app.website {
                    AboutLink(title: "Website", systemImage: "safari", url: website)
                }
                if let support = app.support {
                    AboutLink(title: "Support", systemImage: "questionmark.bubble", url: support)
                }
                if let privacy = app.privacy {
                    AboutLink(title: "Privacy policy", systemImage: "hand.raised", url: privacy)
                }
            }

            Section {
                footer
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden)
    }

    private var header: some View {
        VStack(spacing: 10) {
            app.icon
                .resizable()
                .scaledToFit()
                .frame(width: 88, height: 88)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(.primary.opacity(0.08), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
                .accessibilityHidden(true)
            VStack(spacing: 2) {
                Text(app.name)
                    .font(.title2.bold())
                if let version = Self.version {
                    Text(version)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Text(app.description)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
    }

    private var footer: some View {
        VStack(spacing: 12) {
            if let credits = app.credits {
                Text(credits)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Link(destination: Self.moreApps) {
                HStack(spacing: 4) {
                    Text("Apps by Jon Bobrow")
                    Image(systemName: "arrow.up.right")
                        .font(.caption2.weight(.semibold))
                }
                .font(.footnote.weight(.semibold))
            }
        }
    }

    /// "Version 1.3 (14)"
    private static var version: String? {
        let info = Bundle.main.infoDictionary
        guard let short = info?["CFBundleShortVersionString"] as? String else { return nil }
        let build = info?["CFBundleVersion"] as? String
        return "Version \(short)" + (build.map { " (\($0))" } ?? "")
    }
}

/// A row for an app's own section: an icon, a title, and a chevron.
struct AboutRow: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: systemImage)
                    .foregroundStyle(Color.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(uiColor: .tertiaryLabel))   // not the row's tint
            }
            .contentShape(Rectangle())
        }
    }
}

/// A row that opens a web page.
private struct AboutLink: View {
    let title: String
    let systemImage: String
    let url: URL

    var body: some View {
        Link(destination: url) {
            HStack {
                Label(title, systemImage: systemImage)
                    .foregroundStyle(Color.primary)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(uiColor: .tertiaryLabel))   // not the row's tint
            }
        }
    }
}
