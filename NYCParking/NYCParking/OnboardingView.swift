import SwiftUI
import CoreMotion
import CoreLocation
import UserNotifications

/// First-launch walkthrough: what the map shows, parking reminders, drive mode,
/// then the permissions each feature needs, asked in context.
struct OnboardingView: View {
    @ObservedObject var locationManager: LocationManager
    let driveDetector: DriveDetector
    let onFinish: () -> Void

    @State private var page = 0
    private let pageCount = 5

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                if page < pageCount - 1 {
                    Button("Skip") {
                        withAnimation { page = pageCount - 1 }
                    }
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 44)
                    .padding(.horizontal, 20)
                }
            }
            .frame(height: 44)

            TabView(selection: $page) {
                OnboardingPage(
                    title: "NYC Parking",
                    message: "Alternate-side parking rules for every block in the city, right on the map."
                ) { WelcomeArt() }
                    .tag(0)
                OnboardingPage(
                    title: "Days until you move",
                    message: "Every block is colored by how soon you'd have to move a car parked there. Red means soon, green means you're set for the week."
                ) { CountdownArt() }
                    .tag(1)
                OnboardingPage(
                    title: "Or see cleaning days",
                    message: "Switch views from the layers button to see which days each side of the street is cleaned."
                ) { CleaningDaysArt() }
                    .tag(2)
                OnboardingPage(
                    title: "Park and get reminded",
                    message: "Tap any block and choose Park Here. The banner turns yellow the day before and red in the final hour. Holidays are skipped automatically."
                ) { ParkArt() }
                    .tag(3)
                PermissionsPage(locationManager: locationManager, driveDetector: driveDetector)
                    .tag(4)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            HStack(spacing: 7) {
                ForEach(0..<pageCount, id: \.self) { i in
                    Capsule()
                        .fill(i == page ? Color.primary : Color.secondary.opacity(0.4))
                        .frame(width: i == page ? 20 : 7, height: 7)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: page)
            .padding(.bottom, 20)

            Button {
                if page < pageCount - 1 {
                    withAnimation { page += 1 }
                } else {
                    onFinish()
                }
            } label: {
                Text(page < pageCount - 1 ? "Continue" : "Get started")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(Color.blue, in: Capsule())
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
        }
        .background(Color(red: 0.07, green: 0.075, blue: 0.095).ignoresSafeArea())
        .preferredColorScheme(.dark)
    }
}

/// Illustration on top, then a title and a short explanation.
private struct OnboardingPage<Art: View>: View {
    let title: String
    let message: String
    @ViewBuilder let art: Art

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 12)
            art
                .frame(maxWidth: 340)
                .accessibilityHidden(true)
            Spacer(minLength: 28)
            Text(title)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)
            Text(message)
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
                .padding(.top, 10)
            Spacer(minLength: 20)
        }
        .padding(.horizontal, 24)
    }
}

// MARK: - Illustrations

private struct WelcomeArt: View {
    var body: some View {
        VStack(spacing: 28) {
            Image("AppIconImage")
                .resizable()
                .frame(width: 120, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 27, style: .continuous))
                .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
            HStack(spacing: 4) {
                ForEach(MoveUrgency.allCases, id: \.self) { u in
                    Capsule().fill(u.color).frame(width: 24, height: 8)
                }
            }
        }
    }
}

/// A few blocks of a dark map, north-up like the app zoomed in: a road between
/// two curb lines, each curb with its own color and pill.
private struct StreetsArt<TopPill: View, BottomPill: View>: View {
    struct Street {
        let top: [Color]
        let bottom: [Color]
    }
    let streets: [Street]
    let topPill: (Int) -> TopPill
    let bottomPill: (Int) -> BottomPill

    var body: some View {
        VStack(spacing: 30) {
            ForEach(streets.indices, id: \.self) { i in
                VStack(spacing: 0) {
                    // Curbs (and their pills) draw above the road between them.
                    curb(streets[i].top).overlay(topPill(i).offset(x: i.isMultiple(of: 2) ? -52 : 40))
                        .zIndex(1)
                    Rectangle().fill(Color(red: 0.17, green: 0.18, blue: 0.23)).frame(height: 30)
                    curb(streets[i].bottom).overlay(bottomPill(i).offset(x: i.isMultiple(of: 2) ? 58 : -46))
                        .zIndex(1)
                }
            }
        }
        .padding(.vertical, 34)
        .background(Color(red: 0.11, green: 0.12, blue: 0.16))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(.white.opacity(0.06)))
    }

    private func curb(_ colors: [Color]) -> some View {
        HStack(spacing: 0) {
            ForEach(colors.indices, id: \.self) { colors[$0] }
        }
        .frame(height: 6)
        .padding(.horizontal, 10)
    }
}

private struct CountdownArt: View {
    private let levels = [(1, 3), (0, 5), (6, 7)]

    var body: some View {
        VStack(spacing: 16) {
            StreetsArt(
                streets: levels.map { .init(top: [MoveUrgency(days: $0.0).color], bottom: [MoveUrgency(days: $0.1).color]) },
                topPill: { pill(levels[$0].0) },
                bottomPill: { pill(levels[$0].1) })
            HStack(spacing: 3) {
                ForEach(MoveUrgency.allCases, id: \.self) { u in
                    Text(u.legendLabel)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(u.textColor)
                        .frame(width: 30, height: 20)
                        .background(u.color, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
            }
        }
    }

    private func pill(_ days: Int) -> some View {
        CountdownLabel(countdown: MoveCountdown(days: days, weekday: .monday, startMinutes: 570,
                                                endMinutes: 660, isUnderway: false),
                       style: .days)
            .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
    }
}

private struct CleaningDaysArt: View {
    private let rows: [([ParkingDay], [ParkingDay])] = [
        ([.monday, .thursday], [.tuesday, .friday]),
        ([.wednesday], [.monday, .tuesday, .wednesday, .thursday, .friday, .saturday]),
        ([.tuesday], [.thursday]),
    ]

    var body: some View {
        StreetsArt(
            streets: rows.map { .init(top: $0.0.map(\.color), bottom: $0.1.map(\.color)) },
            topPill: { pill(rows[$0].0) },
            bottomPill: { pill(rows[$0].1) })
    }

    private func pill(_ days: [ParkingDay]) -> some View {
        ParkingLabel(days: days, rule: nil, style: .days)
            .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
    }
}

private struct ParkArt: View {
    var body: some View {
        VStack(spacing: 12) {
            banner("Move by 9:30 AM, Mon Sep 28", icon: "calendar.badge.clock", tint: nil)
            banner("Move by 9:30 AM tomorrow", icon: "calendar.badge.clock", tint: MoveUrgency(days: 3))
            banner("Move in 20 min · 9:30 AM", icon: "clock.badge.exclamationmark.fill", tint: MoveUrgency(days: 0))
            Label("Park Here", systemImage: "car.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: 260, minHeight: 50)
                .background(Color.blue, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.top, 14)
        }
    }

    private func banner(_ text: String, icon: String, tint: MoveUrgency?) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundStyle(tint?.textColor ?? .primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(tint?.color ?? Color.white.opacity(0.12), in: Capsule())
    }
}

private struct DriveArt: View {
    var body: some View {
        VStack(spacing: 8) {
            VStack(spacing: 2) {
                Text("Dekalb Ave").font(.system(size: 18, weight: .bold, design: .rounded))
                Text("Clinton Ave → Waverly Ave")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            HStack(spacing: 8) {
                card(left: true, title: "1 DAY", detail: "Thu 9:30–11 AM", urgency: MoveUrgency(days: 1))
                card(left: false, title: "5 DAYS", detail: "Mon 8:30–10 AM", urgency: MoveUrgency(days: 5))
            }
        }
    }

    private func card(left: Bool, title: String, detail: String, urgency: MoveUrgency) -> some View {
        VStack(alignment: left ? .leading : .trailing, spacing: 2) {
            HStack(spacing: 4) {
                if left { Image(systemName: "arrow.left") }
                Text(left ? "LEFT" : "RIGHT")
                if !left { Image(systemName: "arrow.right") }
            }
            .font(.system(size: 10, weight: .heavy, design: .rounded))
            .opacity(0.75)
            Text(title).font(.system(size: 22, weight: .heavy, design: .rounded))
            Text(detail).font(.system(size: 13, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(urgency.textColor)
        .frame(maxWidth: .infinity, alignment: left ? .leading : .trailing)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(urgency.color, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Permissions

private struct PermissionsPage: View {
    @ObservedObject var locationManager: LocationManager
    let driveDetector: DriveDetector

    @State private var notifications: PermissionState = .notDetermined
    @State private var motion: PermissionState = .notDetermined
    private let motionAvailable = CMMotionActivityManager.isActivityAvailable()

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                DriveArt()
                    .frame(maxWidth: 340)
                    .padding(.top, 8)
                    .accessibilityHidden(true)
                Text("Drive mode")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .padding(.top, 24)
                Text("A 3D view with the rules for each side of the street you're driving down.")
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
                    .padding(.top, 8)

                VStack(spacing: 10) {
                    PermissionRow(icon: "location.fill", title: "Location",
                                  detail: "Centers the map on you and follows you while driving.",
                                  state: locationState) {
                        locationManager.requestPermission()
                    }
                    PermissionRow(icon: "bell.fill", title: "Move reminders",
                                  detail: "A heads-up the evening before and an hour before you need to move.",
                                  state: notifications) {
                        Task {
                            _ = try? await UNUserNotificationCenter.current()
                                .requestAuthorization(options: [.alert, .sound])
                            await refreshNotifications()
                        }
                    }
                    if motionAvailable {
                        PermissionRow(icon: "steeringwheel", title: "Motion",
                                      detail: "Notices when you're driving and offers drive mode.",
                                      state: motion) {
                            Task { motion = await driveDetector.requestMotionAccess() ? .granted : .denied }
                        }
                    }
                }
                .padding(.top, 24)
                .frame(maxWidth: 420)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .scrollBounceBehavior(.basedOnSize)
        .task {
            await refreshNotifications()
            motion = Self.motionState
        }
    }

    private var locationState: PermissionState {
        switch locationManager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: return .granted
        case .denied, .restricted: return .denied
        default: return .notDetermined
        }
    }

    private static var motionState: PermissionState {
        switch CMMotionActivityManager.authorizationStatus() {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        default: return .notDetermined
        }
    }

    private func refreshNotifications() async {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: notifications = .granted
        case .denied: notifications = .denied
        default: notifications = .notDetermined
        }
    }
}

private enum PermissionState { case notDetermined, granted, denied }

private struct PermissionRow: View {
    let icon: String
    let title: String
    let detail: String
    let state: PermissionState
    let request: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(Color.blue, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 16, weight: .bold, design: .rounded))
                Text(detail)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            switch state {
            case .notDetermined:
                Button("Allow", action: request)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 36)
                    .background(Color.blue, in: Capsule())
            case .granted:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.green)
                    .accessibilityLabel("Allowed")
            case .denied:
                Button("Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.blue)
                .frame(minHeight: 36)
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
