import SwiftUI
import MapKit

struct ContentView: View {
    @StateObject private var dataService       = ParkingDataService()
    @StateObject private var locationManager   = LocationManager()
    @StateObject private var reminderService   = ReminderService()
    @StateObject private var holidayService    = ASPHolidayService()

    @State private var position: MapCameraPosition = .region(MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 40.7580, longitude: -73.9855),
        latitudinalMeters: 600, longitudinalMeters: 600))
    @State private var selectedSegment: ParkingSegment?
    @State private var zoomLevel: MarkerZoomLevel = .days
    @State private var annotationGeneration: Int = 0
    @State private var showAnnotationContent: Bool = false
    @State private var pillsVisible: Bool = false
    @State private var pillZoomLevel: MarkerZoomLevel = .days
    @State private var removeAnnotationsTask: Task<Void, Never>? = nil
    @State private var mapHeading: Double = 0
    @State private var lastCamera: MapCamera? = nil
    @State private var hasSnappedToUserLocation = false
    @State private var isFollowingUser = false
    @State private var isDrivingMode = false
    @State private var parkedRecord: ParkedCarRecord?
    @State private var carDragStartOffset: Double = 20
    @State private var carDragTranslation: CGSize = .zero
    @State private var lastMapRegion: MKCoordinateRegion?
    @State private var showReminderPrompt = false
    @State private var pendingReminderDate: Date? = nil
    @State private var showParkedCarSheet = false
    @State private var isCenteredOnCar = false
    @State private var showHolidaySheet = false

    private var screenCornerRadius: CGFloat {
        (UIScreen.main.value(forKey: "_displayCornerRadius") as? CGFloat) ?? 44
    }

    private var windowSafeAreaTop: CGFloat {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?
            .keyWindow?.safeAreaInsets.top ?? 59
    }

    var body: some View {
        ZStack {
            Color.black
            Map(position: $position) {
            if isDrivingMode, let userLoc = locationManager.location {
                Annotation("", coordinate: userLoc.coordinate, anchor: .center) {
                    NavigationArrowView(course: userLoc.course,
                                        speed: userLoc.speed,
                                        mapHeading: mapHeading)
                }
            } else {
                UserAnnotation()
            }

            if let parked = parkedRecord {
                Annotation("", coordinate: carCoordinate(for: parked), anchor: .center) {
                    Image(systemName: "car.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.blue, in: Circle())
                        .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 2)
                        .offset(x: carDragTranslation.width, y: carDragTranslation.height)
                        .onTapGesture { showParkedCarSheet = true }
                        .gesture(
                            DragGesture(minimumDistance: 5)
                                .onChanged { value in
                                    let θ = (parked.streetBearing ?? 0 - mapHeading) * .pi / 180
                                    let sx = sin(θ), sy = -cos(θ)
                                    let proj = value.translation.width * sx + value.translation.height * sy
                                    carDragTranslation = CGSize(width: proj * sx, height: proj * sy)
                                }
                                .onEnded { value in
                                    guard let region = lastMapRegion else {
                                        carDragTranslation = .zero; return
                                    }
                                    let θ = (parked.streetBearing ?? 0 - mapHeading) * .pi / 180
                                    let sx = sin(θ), sy = -cos(θ)
                                    let proj = value.translation.width * sx + value.translation.height * sy
                                    let mPerPoint = region.span.latitudeDelta * 111_320.0
                                                  / UIScreen.main.bounds.height
                                    var newOffset = carDragStartOffset + proj * mPerPoint
                                    let clearance = 12.0
                                    if abs(newOffset) < clearance {
                                        newOffset = newOffset >= 0 ? clearance : -clearance
                                    }
                                    let limit = parked.halfBlockLengthMeters
                                    newOffset = max(-limit, min(limit, newOffset))
                                    parkedRecord?.offsetMeters = newOffset
                                    carDragStartOffset = newOffset
                                    carDragTranslation = .zero
                                }
                        )
                }
            }

            if showAnnotationContent {
                ForEach(dataService.segments) { segment in
                    Annotation("", coordinate: segment.sidewalkCoordinate, anchor: .center) {
                        ParkingLabel(segment: segment, zoomLevel: pillZoomLevel, mapHeading: mapHeading,
                                     onTap: { selectedSegment = segment })
                            .scaleEffect(pillsVisible ? 1 : 0)
                            .opacity(pillsVisible ? 1 : 0)
                            .animation(.spring(response: 0.45, dampingFraction: 0.7), value: pillsVisible)
                            .id(annotationGeneration)
                    }
                }
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .ignoresSafeArea()
        .clipShape(RoundedRectangle(cornerRadius: screenCornerRadius, style: .continuous))
        .onMapCameraChange(frequency: .continuous) { ctx in
            mapHeading = ctx.camera.heading
            lastCamera = ctx.camera
            lastMapRegion = ctx.region
            let delta = ctx.region.span.latitudeDelta
            let newZoom: MarkerZoomLevel = delta < 0.002 ? .full
                                         : delta < 0.006 ? .days
                                         : .dot
            guard newZoom != zoomLevel else { return }
            if zoomLevel == .dot {
                // Entering pill view: cancel any pending removal, start entry animation
                removeAnnotationsTask?.cancel()
                annotationGeneration += 1
                pillZoomLevel = newZoom
                showAnnotationContent = true
                // Defer pillsVisible so annotations render at scale=0 before animating in
                DispatchQueue.main.async { pillsVisible = true }
            } else if newZoom == .dot {
                // Entering dot view: animate pills out, then remove from map content
                pillsVisible = false
                removeAnnotationsTask?.cancel()
                removeAnnotationsTask = Task {
                    try? await Task.sleep(for: .seconds(0.5))
                    showAnnotationContent = false
                }
            } else {
                pillZoomLevel = newZoom
            }
            zoomLevel = newZoom
        }
        .onMapCameraChange(frequency: .onEnd) { ctx in
            dataService.loadRegion(ctx.region)

            let mapCenter = CLLocation(latitude: ctx.region.center.latitude,
                                       longitude: ctx.region.center.longitude)
            if isFollowingUser, let userLoc = locationManager.location,
               mapCenter.distance(from: userLoc) > 80 {
                isFollowingUser = false
                isDrivingMode = false
            }
            if let parked = parkedRecord {
                let coord = carCoordinate(for: parked)
                let carLoc = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
                isCenteredOnCar = mapCenter.distance(from: carLoc) < 80
            }
        }
        .mapControls { }
        .overlay {
            if zoomLevel == .dot {
                MapDotsLayer(segments: dataService.segments, region: lastMapRegion, heading: mapHeading)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .top) {
            if let moveDate = nextMoveDate {
                moveCarBanner(for: moveDate)
                    .onTapGesture { showParkedCarSheet = true }
                    .padding(.top, windowSafeAreaTop + 10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: nextMoveDate != nil)
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
            if zoomLevel == .dot {
                dotLegend
                    .padding(16)
                    .padding(.bottom, 24)
                    .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .bottomLeading)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: zoomLevel == .dot)
        .overlay(alignment: .bottomTrailing) {
            VStack(spacing: 10) {
                if abs(mapHeading) > 1 {
                    Button {
                        if let cam = lastCamera {
                            position = .camera(MapCamera(
                                centerCoordinate: cam.centerCoordinate,
                                distance: cam.distance,
                                heading: 0,
                                pitch: cam.pitch
                            ))
                        }
                    } label: {
                        compassNeedle
                            .rotationEffect(.degrees(-mapHeading))
                    }
                    .buttonStyle(GlassCircleButtonStyle())
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }

                Button {
                    guard let loc = locationManager.location else {
                        position = .userLocation(fallback: .automatic)
                        isFollowingUser = true
                        return
                    }
                    if !isFollowingUser {
                        // Off → On: center on user, normal follow
                        isFollowingUser = true
                        isDrivingMode = false
                        withAnimation(.easeInOut(duration: 0.4)) {
                            position = .region(MKCoordinateRegion(
                                center: loc.coordinate,
                                latitudinalMeters: 300,
                                longitudinalMeters: 300
                            ))
                        }
                    } else if !isDrivingMode {
                        // On → Driving: enable course-up navigation
                        isDrivingMode = true
                        let heading = (loc.course >= 0 && loc.speed > 0.5) ? loc.course : mapHeading
                        withAnimation(.easeInOut(duration: 0.4)) {
                            position = .camera(MapCamera(
                                centerCoordinate: loc.coordinate,
                                distance: lastCamera?.distance ?? 1000,
                                heading: heading,
                                pitch: 0
                            ))
                        }
                    } else {
                        // Driving → On: exit driving, reset heading to north
                        isDrivingMode = false
                        withAnimation(.easeInOut(duration: 0.4)) {
                            position = .camera(MapCamera(
                                centerCoordinate: loc.coordinate,
                                distance: lastCamera?.distance ?? 1000,
                                heading: 0,
                                pitch: 0
                            ))
                        }
                    }
                } label: {
                    Image(systemName: isDrivingMode ? "location.north.fill"
                                    : isFollowingUser ? "location.fill"
                                    : "location")
                        .font(.system(size: 17))
                }
                .buttonStyle(GlassCircleButtonStyle(isDriving: isDrivingMode))

                if let parked = parkedRecord {
                    Button {
                        if isCenteredOnCar {
                            showParkedCarSheet = true
                        } else {
                            isCenteredOnCar = true
                            withAnimation(.easeInOut(duration: 0.4)) {
                                position = .region(MKCoordinateRegion(
                                    center: carCoordinate(for: parked),
                                    latitudinalMeters: 600,
                                    longitudinalMeters: 600
                                ))
                            }
                        }
                    } label: {
                        Image(systemName: isCenteredOnCar ? "car.fill" : "car")
                            .font(.system(size: 17))
                    }
                    .buttonStyle(GlassCircleButtonStyle())
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }

                Button {
                    showHolidaySheet = true
                } label: {
                    Image(systemName: "calendar")
                        .font(.system(size: 17))
                }
                .buttonStyle(GlassCircleButtonStyle())
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
                    } else {
                        let record = ParkedCarRecord(segment: segment, offsetMeters: 20)
                        parkedRecord = record
                        carDragStartOffset = 20
                        carDragTranslation = .zero
                        record.save()
                        pendingReminderDate = nextMoveDate
                        showReminderPrompt = true
                    }
                }
            )
                .presentationDetents([.fraction(0.42)])
                .presentationCornerRadius(22)
                .presentationBackground(.regularMaterial)
                .presentationDragIndicator(.hidden)
        }
        .onAppear {
            locationManager.requestPermission()
            if let record = ParkedCarRecord.load() {
                parkedRecord = record
                carDragStartOffset = record.offsetMeters
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
        .alert("Add a Reminder?", isPresented: $showReminderPrompt) {
            Button("Add Reminder") {
                if let date = pendingReminderDate {
                    let df = DateFormatter()
                    df.dateFormat = "EEE, MMM d"
                    let title = "Move your car — \(df.string(from: date))"
                    Task { await reminderService.scheduleReminder(title: title, on: date) }
                }
            }
            Button("Not Now", role: .cancel) { }
        } message: {
            reminderAlertMessage
        }
        .onAppear {
            dataService.checkForUpdates()
        }
        .onChange(of: locationManager.location) { _, newLocation in
            guard let loc = newLocation else { return }
            if !hasSnappedToUserLocation {
                hasSnappedToUserLocation = true
                isFollowingUser = true
                withAnimation(.easeInOut(duration: 0.6)) {
                    position = .region(MKCoordinateRegion(
                        center: loc.coordinate,
                        latitudinalMeters: 600,
                        longitudinalMeters: 600
                    ))
                }
            } else if isFollowingUser {
                if isDrivingMode {
                    // Driving mode: course-up, rotate map to match travel direction
                    let targetHeading = (loc.course >= 0 && loc.speed > 0.5) ? loc.course : mapHeading
                    position = .camera(MapCamera(
                        centerCoordinate: loc.coordinate,
                        distance: lastCamera?.distance ?? 1000,
                        heading: targetHeading,
                        pitch: 0
                    ))
                } else {
                    // Normal follow: re-center, keep current zoom and heading
                    position = .region(MKCoordinateRegion(
                        center: loc.coordinate,
                        span: lastMapRegion?.span ?? MKCoordinateSpan(
                            latitudeDelta: 0.003, longitudeDelta: 0.003
                        )
                    ))
                }
            }
        }
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

    // MARK: - Move car banner

    private var nextMoveDate: Date? {
        guard let record = parkedRecord else { return nil }
        let restrictionDayValues = Set(record.restrictionRules.flatMap { $0.days })
        guard !restrictionDayValues.isEmpty else { return nil }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        for offset in 1...14 {
            guard let candidate = cal.date(byAdding: .day, value: offset, to: today) else { continue }
            let weekday = cal.component(.weekday, from: candidate)
            guard let day = ParkingDay.from(weekday: weekday),
                  restrictionDayValues.contains(day.rawValue) else { continue }
            if !holidayService.isHoliday(candidate, calendar: cal) {
                return candidate
            }
        }
        return nil
    }

    private var reminderAlertMessage: Text {
        guard let date = pendingReminderDate else {
            return Text("No upcoming restrictions found in the next two weeks.")
        }
        let df = DateFormatter()
        df.dateFormat = "EEEE, MMMM d"
        return Text("Get an 8 AM reminder to move your car on \(df.string(from: date)).")
    }

    private func moveCarBanner(for date: Date) -> some View {
        let df = DateFormatter()
        df.dateFormat = "EEE, MMM d"
        return Label("Move by \(df.string(from: date))", systemImage: "calendar.badge.clock")
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .glassCapsule()
    }

    private func openDirectionsToCar(for record: ParkedCarRecord) {
        let coord = carCoordinate(for: record)
        let placemark = MKPlacemark(coordinate: coord)
        let mapItem = MKMapItem(placemark: placemark)
        mapItem.name = "My Car"
        mapItem.openInMaps(launchOptions: [
            MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking
        ])
    }

    private func carCoordinate(for record: ParkedCarRecord) -> CLLocationCoordinate2D {
        let bearing = (record.streetBearing ?? 0) * .pi / 180
        let mPerDegLat = 111_320.0
        let mPerDegLon = mPerDegLat * cos(record.coordinateLatitude * .pi / 180)
        let dlat = cos(bearing) * record.offsetMeters / mPerDegLat
        let dlon = sin(bearing) * record.offsetMeters / mPerDegLon
        return CLLocationCoordinate2D(
            latitude:  record.sidewalkLatitude  + dlat,
            longitude: record.sidewalkLongitude + dlon
        )
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
    func glassCapsule() -> some View {
        if #available(iOS 26, *) {
            glassEffect(in: Capsule())
        } else {
            background(.ultraThinMaterial, in: Capsule())
        }
    }
}

// MARK: - Glass Circle Button Style

private struct GlassCircleButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    var isDriving: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isDriving ? Color.white
                             : colorScheme == .dark ? .white : Color.accentColor)
            .frame(width: 52, height: 52)
            .contentShape(Circle())
            .modifier(GlassCircleModifier(isPressed: configuration.isPressed, isDriving: isDriving))
            .scaleEffect(configuration.isPressed ? 1.15 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.65), value: configuration.isPressed)
    }
}

private struct GlassCircleModifier: ViewModifier {
    let isPressed: Bool
    var isDriving: Bool = false

    func body(content: Content) -> some View {
        if isDriving {
            content
                .background(Color.blue, in: Circle())
                .brightness(isPressed ? 0.15 : 0)
                .shadow(color: .blue.opacity(0.55), radius: 10, x: 0, y: 0)
        } else if #available(iOS 26, *) {
            content.glassEffect(in: Circle())
        } else {
            content
                .background(.ultraThinMaterial, in: Circle())
                .brightness(isPressed ? 0.1 : 0)
                .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
        }
    }
}

// MARK: - Navigation Arrow Annotation

/// User location marker for driving mode. Shows a directional arrow when moving
/// (rotated to travel direction in screen space) and a dot when stationary.
private struct NavigationArrowView: View {
    let course: Double      // CLLocation.course — degrees CW from north, or -1 if invalid
    let speed: Double       // CLLocation.speed in m/s
    let mapHeading: Double  // current map heading in degrees CW from north

    private var showArrow: Bool { course >= 0 && speed > 0.5 }

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.blue)
                .frame(width: 32, height: 32)
                .shadow(color: .black.opacity(0.35), radius: 5, x: 0, y: 2)
            if showArrow {
                // location.north.fill points toward screen-up at 0° rotation.
                // Subtracting mapHeading converts geographic course to screen angle.
                Image(systemName: "location.north.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .rotationEffect(.degrees(course - mapHeading))
            } else {
                Circle()
                    .fill(.white)
                    .frame(width: 12, height: 12)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showArrow)
        .animation(.interactiveSpring(response: 0.35, dampingFraction: 0.8),
                   value: course - mapHeading)
    }
}

