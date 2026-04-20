import SwiftUI
import MapKit

struct ContentView: View {
    @StateObject private var dataService    = ParkingDataService()
    @StateObject private var locationManager = LocationManager()

    @State private var position: MapCameraPosition = .region(MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 40.7580, longitude: -73.9855),
        latitudinalMeters: 600,
        longitudinalMeters: 600
    ))
    @State private var selectedSegment: ParkingSegment?
    @State private var zoomLevel: MarkerZoomLevel = .days
    @State private var mapHeading: Double = 0
    @State private var lastCamera: MapCamera? = nil
    @State private var hasSnappedToUserLocation = false
    @State private var isFollowingUser = false
    @State private var parkedRecord: ParkedCarRecord?
    @State private var carDragStartOffset: Double = 20
    @State private var carDragTranslation: CGSize = .zero
    @State private var lastMapRegion: MKCoordinateRegion?
    @State private var departingSegments: [ParkingSegment] = []

    private var screenCornerRadius: CGFloat {
        (UIScreen.main.value(forKey: "_displayCornerRadius") as? CGFloat) ?? 44
    }

    var body: some View {
        ZStack {
            Color.black
            Map(position: $position) {
            UserAnnotation()

            if let parked = parkedRecord {
                Annotation("", coordinate: carCoordinate(for: parked), anchor: .center) {
                    Image(systemName: "car.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.blue, in: Circle())
                        .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 2)
                        .offset(carDragTranslation)
                        .onTapGesture { openDirectionsToCar(for: parked) }
                        .gesture(
                            DragGesture()
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

            if zoomLevel != .hidden {
                ForEach(dataService.segments) { segment in
                    Annotation("", coordinate: segment.sidewalkCoordinate, anchor: .center) {
                        ParkingLabel(segment: segment, zoomLevel: zoomLevel, mapHeading: mapHeading,
                                     onTap: { selectedSegment = segment })
                            .id(zoomLevel)
                            .modifier(MarkerAppearAnimation())
                    }
                }
                ForEach(departingSegments) { segment in
                    Annotation("", coordinate: segment.sidewalkCoordinate, anchor: .center) {
                        ParkingLabel(segment: segment, zoomLevel: zoomLevel, mapHeading: mapHeading)
                            .modifier(MarkerDepartAnimation())
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
        }
        .onMapCameraChange(frequency: .onEnd) { ctx in
            let delta = ctx.region.span.latitudeDelta
            zoomLevel = delta < 0.002 ? .full
                      : delta < 0.006 ? .days
                      : delta < 0.015 ? .dot
                      : .hidden
            dataService.fetchSigns(near: ctx.region.center)

            if let userLoc = locationManager.location {
                let center = CLLocation(latitude: ctx.region.center.latitude,
                                        longitude: ctx.region.center.longitude)
                isFollowingUser = center.distance(from: userLoc) < 80
            }
        }
        .mapControls { }
        .overlay(alignment: .top) {
            if let moveDate = nextMoveDate {
                moveCarBanner(for: moveDate)
                    .padding(.top, 8)
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
        .overlay {
            if zoomLevel == .hidden {
                Text("Zoom in to see\nparking restrictions")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                    .glassCapsule()
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: zoomLevel == .hidden)
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
                if dataService.isLoading {
                    ProgressView()
                        .tint(.secondary)
                        .padding(10)
                        .glassCircle()
                }

                if abs(mapHeading) > 1 {
                    Button {
                        withAnimation(.easeInOut(duration: 0.4)) {
                            if let cam = lastCamera {
                                position = .camera(MapCamera(
                                    centerCoordinate: cam.centerCoordinate,
                                    distance: cam.distance,
                                    heading: 0,
                                    pitch: cam.pitch
                                ))
                            } else {
                                position = .userLocation(fallback: .automatic)
                            }
                        }
                    } label: {
                        compassNeedle
                            .rotationEffect(.degrees(-mapHeading))
                    }
                    .buttonStyle(GlassCircleButtonStyle())
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }

                Button {
                    isFollowingUser = true
                    withAnimation(.easeInOut(duration: 0.4)) {
                        if let loc = locationManager.location {
                            position = .region(MKCoordinateRegion(
                                center: loc.coordinate,
                                latitudinalMeters: 600,
                                longitudinalMeters: 600
                            ))
                        } else {
                            position = .userLocation(fallback: .automatic)
                        }
                    }
                } label: {
                    Image(systemName: isFollowingUser ? "location.fill" : "location")
                        .font(.system(size: 17))
                        .foregroundStyle(.white)
                }
                .buttonStyle(GlassCircleButtonStyle())

                if let parked = parkedRecord {
                    Button {
                        withAnimation(.easeInOut(duration: 0.4)) {
                            position = .region(MKCoordinateRegion(
                                center: carCoordinate(for: parked),
                                latitudinalMeters: 600,
                                longitudinalMeters: 600
                            ))
                        }
                    } label: {
                        Image(systemName: "car.fill")
                            .font(.system(size: 17))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(GlassCircleButtonStyle())
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
            .padding(16)
            .padding(.bottom, 24)
            .animation(.easeInOut(duration: 0.25), value: abs(mapHeading) > 1)
            .animation(.easeInOut(duration: 0.25), value: parkedRecord != nil)
        }
        .sheet(item: $selectedSegment) { segment in
            ParkingDetailSheet(
                segment: segment,
                isParked: parkedRecord?.segmentID == segment.id,
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
        }
        .onChange(of: dataService.segments) { old, new in
            let newIDs = Set(new.map(\.id))
            let departed = old.filter { !newIDs.contains($0.id) }
            guard !departed.isEmpty else { return }
            departingSegments = departed
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                departingSegments = []
            }
        }
        .onChange(of: locationManager.location) { _, newLocation in
            guard let loc = newLocation else { return }
            dataService.fetchSigns(near: loc.coordinate)
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
            if !NYCHolidayCalendar.isHoliday(candidate, calendar: cal) {
                return candidate
            }
        }
        return nil
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
            Capsule().fill(.white.opacity(0.55)).frame(width: 4, height: 9).offset(y: 5)
            Capsule().fill(Color.red).frame(width: 4, height: 9).offset(y: -5)
            Circle().fill(.white.opacity(0.8)).frame(width: 4, height: 4)
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
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 52, height: 52)
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

// MARK: - Marker Animations

private struct MarkerAppearAnimation: ViewModifier {
    @State private var scale: CGFloat = 0
    @State private var opacity: Double = 0

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .opacity(opacity)
            .onAppear {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) {
                    scale = 1
                    opacity = 1
                }
            }
    }
}

private struct MarkerDepartAnimation: ViewModifier {
    @State private var scale: CGFloat = 1
    @State private var opacity: Double = 1

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .opacity(opacity)
            .onAppear {
                withAnimation(.easeIn(duration: 0.2)) {
                    scale = 0
                    opacity = 0
                }
            }
    }
}
