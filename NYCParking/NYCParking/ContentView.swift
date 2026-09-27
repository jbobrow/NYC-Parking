import SwiftUI
import MapKit

struct ContentView: View {
    @StateObject private var dataService           = ParkingDataService()
    @StateObject private var locationManager       = LocationManager()
    @StateObject private var notificationService   = NotificationService()
    @StateObject private var holidayService        = ASPHolidayService()

    @State private var mapController = MapController()
    @State private var selectedSegment: ParkingSegment?
    @State private var labelsVisible = false
    @State private var mapHeading: Double = 0
    @State private var hasSnappedToUserLocation = false
    @State private var isFollowingUser = false
    @State private var isDrivingMode = false
    @State private var parkedRecord: ParkedCarRecord?
    @State private var showParkedCarSheet = false
    @State private var isCenteredOnCar = false
    @State private var showHolidaySheet = false
    @State private var displayMode: MapDisplayMode = .countdown
    /// Always on in the app; screenshot scenes can turn it off for a cleaner map.
    @State private var showsHolidayBanner = true
    @Environment(\.scenePhase) private var scenePhase

    private var screenCornerRadius: CGFloat {
        (UIScreen.main.value(forKey: "_displayCornerRadius") as? CGFloat) ?? 44
    }

    /// The window's top safe-area inset (the root view ignores the safe area).
    /// Read once in `onAppear` and stored: reading UIKit insets while SwiftUI is
    /// evaluating the body creates an AttributeGraph cycle that stalls updates.
    @State private var windowSafeAreaTop: CGFloat = 59

    private static func currentWindowSafeAreaTop() -> CGFloat? {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?
            .keyWindow?.safeAreaInsets.top
    }

    var body: some View {
        ZStack {
            Color.black
            ParkingMapView(
                controller: mapController,
                index: dataService.index,
                parkedRecord: parkedRecord,
                isDrivingMode: isDrivingMode,
                displayMode: displayMode,
                countdown: dataService.countdown,
                onCameraChange: { camera in
                    if camera.heading != mapHeading { mapHeading = camera.heading }
                },
                onCameraSettled: { camera in
                    let mapCenter = CLLocation(latitude: camera.center.latitude,
                                               longitude: camera.center.longitude)
                    if isFollowingUser, let userLoc = locationManager.location,
                       mapCenter.distance(from: userLoc) > 80 {
                        isFollowingUser = false
                        isDrivingMode = false
                    }
                    if let parked = parkedRecord {
                        let coord = parked.carCoordinate
                        let carLoc = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
                        isCenteredOnCar = mapCenter.distance(from: carLoc) < 80
                    }
                },
                onLabelsVisibleChange: { labelsVisible = $0 },
                onSelectSegment: { selectedSegment = $0 },
                onCarTap: { showParkedCarSheet = true },
                onCarMoved: { offset in parkedRecord?.offsetMeters = offset }
            )
            .ignoresSafeArea()
            .clipShape(RoundedRectangle(cornerRadius: screenCornerRadius, style: .continuous))
        .overlay(alignment: .top) {
            TopBanners(record: parkedRecord,
                       holidays: holidayService.holidays,
                       showsHolidayBanner: showsHolidayBanner,
                       onMoveTap: { showParkedCarSheet = true },
                       onHolidayTap: { showHolidaySheet = true })
                .padding(.horizontal, 16)
                .padding(.top, windowSafeAreaTop + 10)
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(.ultraThinMaterial)
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: 0.50),
                            .init(color: .clear, location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .frame(height: 50)
                .frame(maxWidth: .infinity)
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottomLeading) {
            Group {
                if displayMode == .countdown {
                    countdownLegend
                } else if !labelsVisible {
                    dotLegend
                }
            }
            .padding(16)
            .padding(.bottom, 24)
            .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .bottomLeading)))
        }
        .animation(.easeInOut(duration: 0.2), value: labelsVisible)
        .animation(.easeInOut(duration: 0.2), value: displayMode)
        .overlay(alignment: .bottomTrailing) {
            VStack(spacing: 10) {
                if abs(mapHeading) > 1 {
                    Button {
                        if let cam = mapController.camera {
                            mapController.setCamera(center: cam.centerCoordinate, heading: 0)
                        }
                    } label: {
                        compassNeedle
                            .rotationEffect(.degrees(-mapHeading))
                    }
                    .buttonStyle(GlassCircleButtonStyle())
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }

                Button {
                    centerOnUser()
                } label: {
                    Image(systemName: isFollowingUser ? "location.fill" : "location")
                        .font(.system(size: 17))
                }
                .buttonStyle(GlassCircleButtonStyle())
                .accessibilityLabel("Center on my location")

                if let parked = parkedRecord {
                    Button {
                        if isCenteredOnCar {
                            showParkedCarSheet = true
                        } else {
                            isCenteredOnCar = true
                            mapController.setRegion(center: parked.carCoordinate, meters: 600)
                        }
                    } label: {
                        Image(systemName: isCenteredOnCar ? "car.fill" : "car")
                            .font(.system(size: 17))
                    }
                    .buttonStyle(GlassCircleButtonStyle())
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }

                Menu {
                    Picker("Map view", selection: $displayMode) {
                        Label("Days until move", systemImage: "hourglass")
                            .tag(MapDisplayMode.countdown)
                        Label("Cleaning days", systemImage: "nosign.app")
                            .tag(MapDisplayMode.days)
                    }
                    .pickerStyle(.inline)

                    Toggle("Drive mode", systemImage: "steeringwheel", isOn: Binding(
                        get: { isDrivingMode },
                        set: { if $0 != isDrivingMode { toggleDriving() } }
                    ))

                    Button("Holiday calendar", systemImage: "calendar") {
                        showHolidaySheet = true
                    }
                } label: {
                    // Shows the steering wheel while driving so drive mode stays visible.
                    Image(systemName: isDrivingMode ? "steeringwheel" : "square.3.layers.3d")
                        .font(.system(size: 17))
                        .foregroundStyle(glassIconColor)
                        .frame(width: 52, height: 52)
                        .contentShape(Circle())
                        .modifier(GlassCircleModifier(isPressed: false))
                }
                .accessibilityLabel("Map options")
            }
            .padding(16)
            .padding(.bottom, 24)
            .animation(.easeInOut(duration: 0.25), value: abs(mapHeading) > 1)
            .animation(.easeInOut(duration: 0.25), value: parkedRecord != nil)
            .animation(.easeInOut(duration: 0.25), value: isCenteredOnCar)
        }
        .sheet(isPresented: $showHolidaySheet) {
            HolidaySheet(holidays: holidayService.holidays)
                .presentationDetents([.medium, .large])
                .presentationCornerRadius(22)
                .presentationBackground(.regularMaterial)
                .presentationDragIndicator(.hidden)
        }
        .sheet(item: $selectedSegment) { segment in
            ParkingDetailSheet(
                segment: segment,
                isParked: parkedRecord?.segmentID == segment.id,
                hasAnyParkedCar: parkedRecord != nil,
                onPark: {
                    if parkedRecord?.segmentID == segment.id {
                        parkedRecord = nil
                        ParkedCarRecord.clear()
                        notificationService.cancelPendingNotifications()
                    } else {
                        let record = ParkedCarRecord(segment: segment, offsetMeters: 20)
                        parkedRecord = record
                        record.save()
                        if let date = nextMoveDate {
                            Task { await notificationService.scheduleNotifications(for: record, moveDate: date) }
                        }
                    }
                }
            )
                .presentationDetents([.fraction(0.42)])
                .presentationCornerRadius(22)
                .presentationBackground(.regularMaterial)
                .presentationDragIndicator(.hidden)
        }
        .onAppear {
            if let top = Self.currentWindowSafeAreaTop() { windowSafeAreaTop = top }
            locationManager.requestPermission()
            if let record = ParkedCarRecord.load() {
                parkedRecord = record
            }
        }
        .onChange(of: parkedRecord) { _, record in
            record == nil ? ParkedCarRecord.clear() : record?.save()
            if record == nil { isCenteredOnCar = false }
        }
        .sheet(isPresented: $showParkedCarSheet) {
            if let parked = parkedRecord {
                ParkedCarSheet(
                    record: parked,
                    nextMoveDate: nextMoveDate,
                    onDirections: { openDirectionsToCar(for: parked) },
                    onUnpark: {
                        notificationService.cancelPendingNotifications()
                        withAnimation(.easeInOut(duration: 0.3)) {
                            parkedRecord = nil
                            ParkedCarRecord.clear()
                        }
                    }
                )
                .presentationDetents([.fraction(0.42)])
                .presentationCornerRadius(22)
                .presentationBackground(.regularMaterial)
                .presentationDragIndicator(.hidden)
            }
        }
        .onChange(of: locationManager.location) { _, newLocation in
            guard let loc = newLocation else { return }
            if !hasSnappedToUserLocation {
                hasSnappedToUserLocation = true
                isFollowingUser = true
                mapController.setRegion(center: loc.coordinate, meters: 600)
            } else if isFollowingUser {
                if isDrivingMode {
                    // Driving mode: course-up, rotate map to match travel direction
                    mapController.setCamera(center: loc.coordinate, heading: drivingHeading(for: loc))
                } else {
                    // Normal follow: re-center, keep current zoom and heading
                    mapController.setCenter(loc.coordinate)
                }
            }
        }
        .task(id: countdownRefreshID) {
            // Countdowns shift at midnight and as restrictions end; a few minutes'
            // staleness is fine, and unchanged results don't redraw the map.
            guard displayMode == .countdown, scenePhase == .active else { return }
            while !Task.isCancelled {
                dataService.refreshCountdown(calendar: CountdownCalendar { holidayService.isHoliday($0) })
                try? await Task.sleep(for: .seconds(300))
            }
        }
        #if DEBUG
        .task { await applyScreenshotScene() }
        #endif
        .onChange(of: isDrivingMode) { _, driving in
            if driving {
                locationManager.startNavigationMode()
            } else {
                locationManager.stopNavigationMode()
            }
        }
        } // ZStack
        .ignoresSafeArea()
    }

    #if DEBUG
    /// Stages an App Store screenshot scene (see `ScreenshotScene`).
    private func applyScreenshotScene() async {
        guard let scene = ScreenshotScene.current else { return }
        hasSnappedToUserLocation = true   // keep the first location fix from moving the camera
        isFollowingUser = false
        displayMode = scene.mode
        showsHolidayBanner = scene.showsHolidayBanner
        try? await Task.sleep(for: .milliseconds(300))
        mapController.setRegion(MKCoordinateRegion(center: scene.center,
                                                   latitudinalMeters: scene.spanMeters.lat,
                                                   longitudinalMeters: scene.spanMeters.lon),
                                animated: false)
        mapController.setCamera(center: scene.center, heading: scene.heading, animated: false)

        while dataService.index == nil { try? await Task.sleep(for: .milliseconds(100)) }
        let segments = dataService.index?.segments ?? []
        parkedRecord = scene.parkedSegmentID
            .flatMap { id in segments.first { $0.id == id } }
            .map { ParkedCarRecord(segment: $0, offsetMeters: scene.parkedOffsetMeters) }
        try? await Task.sleep(for: .milliseconds(500))
        selectedSegment = scene.selectedSegmentID.flatMap { id in segments.first { $0.id == id } }
        showHolidaySheet = scene.showsHolidays
    }
    #endif

    // MARK: - Location & drive mode

    /// Centers on the user and follows them (keeping course-up in drive mode).
    private func centerOnUser() {
        isFollowingUser = true
        guard let loc = locationManager.location else {
            mapController.followUser()
            return
        }
        if isDrivingMode {
            mapController.setCamera(center: loc.coordinate, heading: drivingHeading(for: loc))
        } else {
            mapController.setRegion(center: loc.coordinate, meters: 300)
        }
    }

    /// Drive mode: follow the user with the map rotated to the direction of travel.
    private func toggleDriving() {
        if isDrivingMode {
            isDrivingMode = false
            let center = locationManager.location?.coordinate ?? mapController.camera?.centerCoordinate
            if let center { mapController.setCamera(center: center, heading: 0) }
        } else {
            isDrivingMode = true
            isFollowingUser = true
            guard let loc = locationManager.location else {
                mapController.followUser()
                return
            }
            mapController.setCamera(center: loc.coordinate, heading: drivingHeading(for: loc))
        }
    }

    private func drivingHeading(for loc: CLLocation) -> Double {
        (loc.course >= 0 && loc.speed > 0.5) ? loc.course : mapHeading
    }

    /// Restarts the countdown refresh loop whenever its inputs change.
    private var countdownRefreshID: String {
        "\(displayMode.rawValue)|\(dataService.index != nil)|\(holidayService.holidays.count)|\(scenePhase == .active)"
    }

    // MARK: - Move car banner

    private var nextMoveDate: Date? {
        parkedRecord?.nextMoveDate(after: AppClock.now) { holidayService.isHoliday($0) }
    }

    private func openDirectionsToCar(for record: ParkedCarRecord) {
        let coord = record.carCoordinate
        let placemark = MKPlacemark(coordinate: coord)
        let mapItem = MKMapItem(placemark: placemark)
        mapItem.name = "My Car"
        mapItem.openInMaps(launchOptions: [
            MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking
        ])
    }

    private var dotLegend: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(ParkingDay.allCases) { day in
                HStack(spacing: 7) {
                    Circle()
                        .fill(day.color)
                        .frame(width: 9, height: 9)
                    Text(day.short)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 20)
        .padding(.bottom, 20)
        .glassCapsule()
    }

    @Environment(\.colorScheme) private var colorScheme

    private var glassIconColor: Color { colorScheme == .dark ? .white : .accentColor }

    private var countdownLegend: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Days until move")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            HStack(spacing: 3) {
                ForEach(MoveUrgency.allCases, id: \.self) { urgency in
                    VStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(urgency.color)
                            .frame(width: 16, height: 8)
                        Text(urgency.legendLabel)
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(.primary)
                            .fixedSize()
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .glassRoundedRect()
    }

    private var compassNeedle: some View {
        ZStack {
            Capsule().fill(.primary.opacity(0.55)).frame(width: 4, height: 9).offset(y: 5)
            Capsule().fill(Color.red).frame(width: 4, height: 9).offset(y: -5)
            Circle().fill(.primary.opacity(0.8)).frame(width: 4, height: 4)
        }
    }
}

// MARK: - Glass Circle Helper (loading spinner only)

private extension View {
    @ViewBuilder
    func glassCircle() -> some View {
        if #available(iOS 26, *) {
            glassEffect(in: Circle())
        } else {
            background(.ultraThinMaterial, in: Circle())
                .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
        }
    }

    @ViewBuilder
    func glassRoundedRect() -> some View {
        if #available(iOS 26, *) {
            glassEffect(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else {
            background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    @ViewBuilder
    func glassCapsule() -> some View {
        if #available(iOS 26, *) {
            glassEffect(in: Capsule())
        } else {
            background(.ultraThinMaterial, in: Capsule())
        }
    }
}

// MARK: - Banners

/// The move-by and upcoming-holiday banners. A separate view so its inputs are
/// compared on every update (state read inside the TimelineView closure would
/// otherwise go stale until the next tick); the timeline re-evaluates each
/// minute so urgency and wording stay current.
private struct TopBanners: View {
    let record: ParkedCarRecord?
    let holidays: [NamedHoliday]
    let showsHolidayBanner: Bool
    let onMoveTap: () -> Void
    let onHolidayTap: () -> Void

    var body: some View {
        TimelineView(.everyMinute) { _ in
            let now = AppClock.now
            let moveDate = record?.nextMoveDate(after: now) { isHoliday($0) }
            let holiday = showsHolidayBanner ? upcomingHoliday(from: now) : nil
            VStack(spacing: 8) {
                if let moveDate {
                    moveCarBanner(for: moveDate, now: now)
                        .onTapGesture(perform: onMoveTap)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if let holiday {
                    holidayBanner(holiday.holiday, daysAway: holiday.days)
                        .onTapGesture(perform: onHolidayTap)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(.easeInOut(duration: 0.3), value: moveDate)
            .animation(.easeInOut(duration: 0.3), value: holiday?.holiday.id)
            .animation(.easeInOut(duration: 0.3),
                       value: moveDate.map { MoveBannerStage(deadline: $0, now: now) })
        }
    }

    private func isHoliday(_ date: Date) -> Bool {
        holidays.contains { Calendar.current.isDate($0.date, inSameDayAs: date) }
    }

    /// Yellow from the day before the move, red within the final hour.
    private func moveCarBanner(for date: Date, now: Date) -> some View {
        let stage = MoveBannerStage(deadline: date, now: now)
        let time = date.formatted(date: .omitted, time: .shortened)
        let text: String
        switch stage {
        case .imminent:
            let minutes = max(1, Int((date.timeIntervalSince(now) / 60).rounded(.up)))
            text = "Move in \(minutes) min · \(time)"
        case .dayBefore where Calendar.current.isDate(date, inSameDayAs: now):
            text = "Move by \(time) today"
        case .dayBefore:
            text = "Move by \(time) tomorrow"
        case .normal:
            let df = DateFormatter()
            df.dateFormat = "h:mm a, EEE MMM d"
            text = "Move by \(df.string(from: date))"
        }
        let icon = stage == .imminent ? "clock.badge.exclamationmark.fill" : "calendar.badge.clock"
        return Label(text, systemImage: icon)
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .lineLimit(1)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .modifier(BannerBackground(tint: stage.tint))
    }

    /// An ASP holiday within two weeks means a skipped cleaning day.
    private func upcomingHoliday(from now: Date) -> (holiday: NamedHoliday, days: Int)? {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        return holidays
            .compactMap { holiday -> (holiday: NamedHoliday, days: Int)? in
                guard let days = cal.dateComponents([.day], from: today,
                                                    to: cal.startOfDay(for: holiday.date)).day,
                      (0...14).contains(days) else { return nil }
                return (holiday, days)
            }
            .min { $0.days < $1.days }
    }

    private func holidayBanner(_ holiday: NamedHoliday, daysAway: Int) -> some View {
        let when: String
        switch daysAway {
        case 0:  when = "today"
        case 1:  when = "tomorrow"
        default: when = holiday.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        }
        return Label {
            Text("No ASP \(when) · \(holiday.name)")
        } icon: {
            Image(systemName: "calendar.badge.checkmark")
                .foregroundStyle(MoveUrgency(days: MoveUrgency.maxLevel).color)
        }
        .font(.system(size: 14, weight: .semibold, design: .rounded))
        .lineLimit(1)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .modifier(BannerBackground(tint: nil))
    }
}

/// How close the move-by deadline is.
private enum MoveBannerStage: Equatable {
    case normal     // two or more days out
    case dayBefore  // the day before, or the day of (more than an hour away)
    case imminent   // within the hour

    init(deadline: Date, now: Date) {
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: now),
                                      to: cal.startOfDay(for: deadline)).day ?? 0
        if deadline.timeIntervalSince(now) <= 3600 {
            self = .imminent
        } else if days <= 1 {
            self = .dayBefore
        } else {
            self = .normal
        }
    }

    /// Matches the countdown map: yellow (3 days) and red (today) steps.
    var tint: MoveUrgency? {
        switch self {
        case .normal:    return nil
        case .dayBefore: return MoveUrgency(days: 3)
        case .imminent:  return MoveUrgency(days: 0)
        }
    }
}

/// Glass capsule, or a solid urgency color with contrasting text.
private struct BannerBackground: ViewModifier {
    let tint: MoveUrgency?

    func body(content: Content) -> some View {
        if let tint {
            content
                .foregroundStyle(tint.textColor)
                .background(tint.color, in: Capsule())
                .shadow(color: tint.color.opacity(0.55), radius: 10, x: 0, y: 2)
        } else if #available(iOS 26, *) {
            content
                .foregroundStyle(.primary)
                .glassEffect(in: Capsule())
        } else {
            content
                .foregroundStyle(.primary)
                .background(.ultraThinMaterial, in: Capsule())
        }
    }
}

// MARK: - Glass Buttons

private struct GlassCircleButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(colorScheme == .dark ? .white : Color.accentColor)
            .frame(width: 52, height: 52)
            .contentShape(Circle())
            .modifier(GlassCircleModifier(isPressed: configuration.isPressed))
            .scaleEffect(configuration.isPressed ? 1.15 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.65), value: configuration.isPressed)
    }
}

private struct GlassCircleModifier: ViewModifier {
    let isPressed: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.glassEffect(in: Circle())
        } else {
            content
                .background(.ultraThinMaterial, in: Circle())
                .brightness(isPressed ? 0.1 : 0)
                .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
        }
    }
}
