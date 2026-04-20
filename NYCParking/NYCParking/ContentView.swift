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
    @State private var parkedSegment: ParkingSegment?
    @State private var carOffsetMeters: Double = 20
    @State private var carDragStartOffset: Double = 20
    @State private var carDragTranslation: CGSize = .zero
    @State private var lastMapRegion: MKCoordinateRegion?

    var body: some View {
        Map(position: $position) {
            UserAnnotation()

            if let parked = parkedSegment {
                Annotation("", coordinate: carCoordinate(for: parked), anchor: .center) {
                    Image(systemName: "car.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.blue, in: Circle())
                        .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 2)
                        .offset(carDragTranslation)
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    // Project the screen drag onto the street direction.
                                    // Street bearing on screen = (bearing − mapHeading), CW from up.
                                    let θ = (parked.streetBearing ?? 0 - mapHeading) * .pi / 180
                                    let sx = sin(θ), sy = -cos(θ)   // street unit vector in screen space
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
                                    // Keep car out of the label dead-zone (±12 m)
                                    let clearance = 12.0
                                    if abs(newOffset) < clearance {
                                        newOffset = newOffset >= 0 ? clearance : -clearance
                                    }
                                    // Clamp to the actual block extent
                                    let limit = parked.halfBlockLengthMeters
                                    newOffset = max(-limit, min(limit, newOffset))
                                    carOffsetMeters = newOffset
                                    carDragStartOffset = newOffset
                                    carDragTranslation = .zero
                                }
                        )
                }
            }

            if zoomLevel != .hidden {
                ForEach(dataService.segments) { segment in
                    Annotation("", coordinate: segment.sidewalkCoordinate, anchor: .center) {
                        ParkingLabel(segment: segment, zoomLevel: zoomLevel, mapHeading: mapHeading)
                            .contentShape(Rectangle())
                            .onTapGesture { selectedSegment = segment }
                    }
                }
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .ignoresSafeArea()
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
        .safeAreaInset(edge: .top, spacing: 0) {
            if zoomLevel == .hidden {
                Text("Zoom in to see parking restrictions")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassCapsule()
                    .padding(.top, 12)
                    .padding(.bottom, 4)
                    .frame(maxWidth: .infinity)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: zoomLevel == .hidden)
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

                if let parked = parkedSegment {
                    Button {
                        withAnimation(.easeInOut(duration: 0.4)) {
                            position = .region(MKCoordinateRegion(
                                center: parked.sidewalkCoordinate,
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
            .animation(.easeInOut(duration: 0.25), value: parkedSegment != nil)
        }
        .sheet(item: $selectedSegment) { segment in
            ParkingDetailSheet(
                segment: segment,
                isParked: parkedSegment?.id == segment.id,
                onPark: {
                    if parkedSegment?.id == segment.id {
                        parkedSegment = nil
                    } else {
                        parkedSegment = segment
                        carOffsetMeters = 20
                        carDragStartOffset = 20
                        carDragTranslation = .zero
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
    }

    private func carCoordinate(for segment: ParkingSegment) -> CLLocationCoordinate2D {
        let bearing = (segment.streetBearing ?? 0) * .pi / 180
        let lat = segment.coordinate.latitude
        let mPerDegLat = 111_320.0
        let mPerDegLon = mPerDegLat * cos(lat * .pi / 180)
        let dlat = cos(bearing) * carOffsetMeters / mPerDegLat
        let dlon = sin(bearing) * carOffsetMeters / mPerDegLon
        return CLLocationCoordinate2D(
            latitude:  segment.sidewalkCoordinate.latitude  + dlat,
            longitude: segment.sidewalkCoordinate.longitude + dlon
        )
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
