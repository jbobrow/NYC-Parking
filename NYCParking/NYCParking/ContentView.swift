import SwiftUI
import MapKit

struct ContentView: View {
    @StateObject private var dataService    = ParkingDataService()
    @StateObject private var locationManager = LocationManager()

    @State private var position: MapCameraPosition = .userLocation(
        fallback: .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 40.7580, longitude: -73.9855),
            latitudinalMeters: 500,
            longitudinalMeters: 500
        ))
    )
    @State private var selectedSegment: ParkingSegment?

    var body: some View {
        Map(position: $position) {
            UserAnnotation()

            ForEach(dataService.segments) { segment in
                Annotation("", coordinate: segment.coordinate, anchor: .center) {
                    ParkingLabel(segment: segment)
                        .contentShape(Rectangle())
                        .onTapGesture { selectedSegment = segment }
                }
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .ignoresSafeArea()
        .onMapCameraChange(frequency: .onEnd) { ctx in
            dataService.fetchSigns(near: ctx.region.center)
        }
        .overlay(alignment: .bottomTrailing) {
            VStack(spacing: 10) {
                if dataService.isLoading {
                    ProgressView()
                        .tint(.secondary)
                        .padding(10)
                        .background(.regularMaterial, in: Circle())
                }

                Button {
                    withAnimation(.easeInOut(duration: 0.4)) {
                        position = .userLocation(fallback: .automatic)
                    }
                } label: {
                    Image(systemName: "location.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(.blue)
                        .frame(width: 44, height: 44)
                        .background(.regularMaterial, in: Circle())
                        .shadow(color: .black.opacity(0.12), radius: 4, x: 0, y: 2)
                }
            }
            .padding(16)
            .padding(.bottom, 24)
        }
        .sheet(item: $selectedSegment) { segment in
            ParkingDetailSheet(segment: segment)
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
        }
    }
}
