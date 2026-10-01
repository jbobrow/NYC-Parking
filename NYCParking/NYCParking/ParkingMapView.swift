import SwiftUI
import MapKit

// MARK: - Public API

/// Snapshot of the map camera, reported to SwiftUI as the map moves.
struct MapCameraState {
    let center: CLLocationCoordinate2D
    let heading: Double
    let distance: CLLocationDistance
}

/// Imperative camera control for `ParkingMapView` (set region, follow, reset heading).
@MainActor
final class MapController {
    fileprivate weak var mapView: MKMapView?
    fileprivate weak var drive: DriveController?

    var camera: MKMapCamera? { mapView?.camera }

    /// Drive mode: go back to following the car after the user moved the map.
    func recenterDrive() {
        drive?.resume()
    }

    /// Leaves drive mode's 3D camera for a flat, north-up view.
    func endDrive(center: CLLocationCoordinate2D?) {
        drive?.stop()
        guard let mapView else { return }
        let camera = MKMapCamera(lookingAtCenter: center ?? mapView.centerCoordinate,
                                 fromDistance: 700, pitch: 0, heading: 0)
        mapView.setCamera(camera, animated: true)
    }

    func setRegion(center: CLLocationCoordinate2D, meters: CLLocationDistance, animated: Bool = true) {
        mapView?.setRegion(MKCoordinateRegion(center: center, latitudinalMeters: meters,
                                              longitudinalMeters: meters), animated: animated)
    }

    func setRegion(_ region: MKCoordinateRegion, animated: Bool = true) {
        mapView?.setRegion(region, animated: animated)
    }

    /// Re-centers without changing zoom or heading.
    func setCenter(_ center: CLLocationCoordinate2D, animated: Bool = true) {
        mapView?.setCenter(center, animated: animated)
    }

    func setCamera(center: CLLocationCoordinate2D, distance: CLLocationDistance? = nil,
                   heading: CLLocationDirection, animated: Bool = true) {
        guard let mapView else { return }
        let camera = MKMapCamera(lookingAtCenter: center,
                                 fromDistance: distance ?? mapView.camera.centerCoordinateDistance,
                                 pitch: 0, heading: heading)
        mapView.setCamera(camera, animated: animated)
    }

    func followUser() {
        mapView?.setUserTrackingMode(.follow, animated: true)
    }
}

/// The parking map. Block faces are drawn as vector `MKMultiPolyline` overlays,
/// which MapKit keeps glued to the street at any zoom or rotation with no
/// per-frame work from us:
///
///  - **Days mode** — zoomed in, a stripe down each parking lane split into one
///    colored piece per restricted day; zoomed out, a run of day-colored dots.
///  - **Countdown mode** — one solid line per block at every zoom, colored by how
///    soon a car parked there must move.
///
/// When zoomed in, a pill sits on each block. Pills are native annotation views
/// whose rotation we update as the map rotates, with overlapping pills hidden
/// (the stripe still carries the information).
struct ParkingMapView: UIViewRepresentable {
    let controller: MapController
    let index: SegmentIndex?
    let parkedRecord: ParkedCarRecord?
    let isDrivingMode: Bool
    let displayMode: MapDisplayMode
    let countdown: CountdownSnapshot?
    let meters: MeterSnapshot?
    /// Latest location while driving; drives the 3D camera.
    var driveLocation: CLLocation? = nil
    var onDriveMatch: (DriveMatch?) -> Void = { _ in }
    /// Whether drive mode is following the car (false after the user moves the map).
    var onDriveFollowChange: (Bool) -> Void = { _ in }
    var onCameraChange: (MapCameraState) -> Void = { _ in }
    var onCameraSettled: (MapCameraState) -> Void = { _ in }
    var onLabelsVisibleChange: (Bool) -> Void = { _ in }
    var onSelectSegment: (ParkingSegment) -> Void = { _ in }
    var onCarTap: () -> Void = {}
    /// The car was dragged along the block; the new offset from the block midpoint.
    var onCarMoved: (Double) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = true
        mapView.showsCompass = false
        mapView.showsScale = false
        mapView.pointOfInterestFilter = .excludingAll
        mapView.register(SegmentLabelView.self,
                         forAnnotationViewWithReuseIdentifier: SegmentLabelView.reuseID)
        mapView.setRegion(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 40.7580, longitude: -73.9855),
            latitudinalMeters: 600, longitudinalMeters: 600), animated: false)
        controller.mapView = mapView
        controller.drive = context.coordinator.drive
        context.coordinator.install(on: mapView)
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update(index: index, parkedRecord: parkedRecord, isDriving: isDrivingMode,
                                   displayMode: displayMode, countdown: countdown, meters: meters)
        if let driveLocation { context.coordinator.drive.ingest(driveLocation) }
    }
}

// MARK: - Coordinator

extension ParkingMapView {
    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var parent: ParkingMapView
        private weak var mapView: MKMapView?

        private var index: SegmentIndex?
        private var displayMode: MapDisplayMode = .days
        private var countdown: CountdownSnapshot?
        private var meters: MeterSnapshot?

        /// The overlay layer that should be on the map, and what actually is.
        private enum MarkLayer: Equatable {
            case dayStripes
            case dots(bucket: Int)   // dot spacing is in screen points, so rebuilt per half zoom level
            case countdown
            case meters
        }
        private var layer: MarkLayer?
        private var shownOverlays: [StripeOverlay] = []
        private var dayStripeOverlays: [StripeOverlay]?
        private var countdownOverlays: [StripeOverlay]?
        private var meterOverlays: [StripeOverlay]?
        private var dotCache: (bucket: Int, overlays: [StripeOverlay])?
        private var buildTasks: [String: Task<Void, Never>] = [:]
        private let stripeRenderers = NSHashTable<MKMultiPolylineRenderer>.weakObjects()
        private var stripeWidth: CGFloat = 3

        private var labelStyle: LabelStyle?
        private var labelAnnotations: [String: SegmentAnnotation] = [:]
        private var lastDeclutter: (mpp: Double, heading: Double) = (0, 0)
        private var declutterScheduled = false

        private var parkedRecord: ParkedCarRecord?
        private var carAnnotation: CarAnnotation?
        private var carPan: UIPanGestureRecognizer?
        private var carDrag: (grabOffset: CGSize, offset: Double)?

        private var isDriving = false
        let drive = DriveController()
        private var normalConfiguration: MKMapConfiguration?
        /// MapKit's own pan/pinch/rotate recognizers, for telling user moves from ours.
        private var mapGestures: [UIGestureRecognizer] = []

        init(parent: ParkingMapView) { self.parent = parent }

        func install(on mapView: MKMapView) {
            self.mapView = mapView
            mapGestures = Self.gestureRecognizers(in: mapView)
            drive.mapView = mapView
            drive.index = { [weak self] in self?.index }
            drive.onMatch = { [weak self] in self?.parent.onDriveMatch($0) }
            drive.onFollowChange = { [weak self] in self?.parent.onDriveFollowChange($0) }
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleMapTap(_:)))
            tap.delegate = self
            // Wait out MapKit's double-tap-to-zoom so a double tap doesn't also select.
            for other in Self.gestureRecognizers(in: mapView) {
                if let t = other as? UITapGestureRecognizer, t.numberOfTapsRequired == 2 {
                    tap.require(toFail: t)
                }
            }
            mapView.addGestureRecognizer(tap)
        }

        private static func gestureRecognizers(in view: UIView) -> [UIGestureRecognizer] {
            (view.gestureRecognizers ?? []) + view.subviews.flatMap { gestureRecognizers(in: $0) }
        }

        // MARK: State from SwiftUI

        func update(index: SegmentIndex?, parkedRecord: ParkedCarRecord?, isDriving: Bool,
                    displayMode: MapDisplayMode, countdown: CountdownSnapshot?, meters: MeterSnapshot?) {
            var marksChanged = false
            if index !== self.index {
                self.index = index
                buildTasks.values.forEach { $0.cancel() }
                buildTasks = [:]
                dayStripeOverlays = nil
                countdownOverlays = nil
                meterOverlays = nil
                dotCache = nil
                marksChanged = true
            }
            if countdown !== self.countdown {
                self.countdown = countdown
                countdownOverlays = nil
                buildTasks["countdown"]?.cancel()
                marksChanged = true
            }
            if meters !== self.meters {
                self.meters = meters
                meterOverlays = nil
                buildTasks["meters"]?.cancel()
                marksChanged = true
            }
            if displayMode != self.displayMode {
                self.displayMode = displayMode
                marksChanged = true
            }
            if marksChanged, let mapView {
                layer = nil   // force re-apply
                updateMarks(mpp: metersPerPoint(mapView))
                refreshLabelContent(mapView)
                refreshLabels()
            }
            if parkedRecord != self.parkedRecord {
                self.parkedRecord = parkedRecord
                syncCar()
            }
            if isDriving != self.isDriving, let mapView {
                self.isDriving = isDriving
                isDriving ? enterDriveMode(mapView) : exitDriveMode(mapView)
            }
        }

        // MARK: Drive mode

        private func enterDriveMode(_ mapView: MKMapView) {
            normalConfiguration = mapView.preferredConfiguration
            // 3D buildings, with the base map toned down so the curb colors stand out.
            let config = MKStandardMapConfiguration(elevationStyle: .realistic, emphasisStyle: .muted)
            config.pointOfInterestFilter = .excludingAll
            mapView.preferredConfiguration = config
            mapView.showsUserLocation = false   // the drive puck replaces the blue dot
            UIApplication.shared.isIdleTimerDisabled = true
            applyStripeWidth(Self.driveStripeWidth)
            layer = nil
            updateMarks(mpp: metersPerPoint(mapView))
            updateLabelStyle(mpp: metersPerPoint(mapView), mapView: mapView)
            drive.start()
        }

        private func exitDriveMode(_ mapView: MKMapView) {
            drive.stop()
            if let normalConfiguration { mapView.preferredConfiguration = normalConfiguration }
            mapView.showsUserLocation = true
            UIApplication.shared.isIdleTimerDisabled = false
            layer = nil
            updateMarks(mpp: metersPerPoint(mapView))
            updateLabelStyle(mpp: metersPerPoint(mapView), mapView: mapView)
        }

        /// Fixed while driving: re-rendering every stripe as the camera zooms with
        /// speed would cause hitches.
        private static let driveStripeWidth: CGFloat = 5

        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            guard isDriving, drive.isFollowing else { return }
            if mapGestures.contains(where: { $0.state == .began || $0.state == .changed }) {
                drive.pause()
            }
        }

        // MARK: Zoom metrics

        /// Ground meters per screen point at the map center — exact under rotation,
        /// unlike the region span (which is the rotated viewport's bounding box).
        private func metersPerPoint(_ mapView: MKMapView) -> Double {
            let c = CGPoint(x: mapView.bounds.midX, y: mapView.bounds.midY)
            let a = mapView.convert(c, toCoordinateFrom: mapView)
            let b = mapView.convert(CGPoint(x: c.x, y: c.y + 100), toCoordinateFrom: mapView)
            let d = CLLocation(latitude: a.latitude, longitude: a.longitude)
                .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
            return max(d / 100, 0.01)
        }

        private func cameraState(_ mapView: MKMapView) -> MapCameraState {
            MapCameraState(center: mapView.centerCoordinate,
                           heading: mapView.camera.heading,
                           distance: mapView.camera.centerCoordinateDistance)
        }

        // MARK: Camera delegate

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            // Drive mode moves the camera every frame: skip SwiftUI updates, labels
            // and decluttering, which only matter when browsing.
            guard !isDriving else { return }
            parent.onCameraChange(cameraState(mapView))
            let mpp = metersPerPoint(mapView)
            updateMarks(mpp: mpp)
            updateLabelStyle(mpp: mpp, mapView: mapView)

            let heading = mapView.camera.heading
            for view in visibleLabelViews(mapView) { view.setHeading(heading) }

            // Re-declutter mid-gesture only once zoom/rotation has changed enough to
            // create or resolve overlaps; panning alone never changes them.
            let zoomChange = abs(mpp / max(lastDeclutter.mpp, 0.001) - 1)
            let headingChange = abs(angleDelta(heading, lastDeclutter.heading))
            if zoomChange > 0.12 || headingChange > 8 { declutter() }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            guard !isDriving else { return }
            parent.onCameraSettled(cameraState(mapView))
            refreshLabels()
            declutter()
        }

        // MARK: Stripes & dots

        private func updateMarks(mpp: Double) {
            if !isDriving { applyStripeWidth(StripeBuilder.lineWidth(metersPerPoint: mpp)) }
            let target: MarkLayer
            if displayMode == .countdown {
                target = .countdown
            } else if displayMode == .meters {
                target = .meters
            } else if isDriving || LabelStyle.forMetersPerPoint(mpp) != nil {
                // Stripes where pills show: they mark each block's extent under its pill.
                target = .dayStripes
            } else {
                target = .dots(bucket: Int((log2(mpp) * 2).rounded()))
            }
            guard target != layer else { return }
            layer = target
            applyLayer()
        }

        private func applyStripeWidth(_ width: CGFloat) {
            guard width != stripeWidth else { return }
            stripeWidth = width
            for renderer in stripeRenderers.allObjects {
                renderer.lineWidth = width
                renderer.setNeedsDisplay()
            }
        }

        /// Shows the current layer's overlays, building them first if needed. The
        /// previous layer stays up until the new one is ready, so there's never a
        /// frame with nothing drawn.
        private func applyLayer() {
            guard let layer, let segments = index?.segments else { return }
            switch layer {
            case .dayStripes:
                if let overlays = dayStripeOverlays { show(overlays); return }
                build("dayStripes", layer: layer) {
                    StripeBuilder.overlays(for: segments)
                } store: { self.dayStripeOverlays = $0 }

            case .countdown:
                if let overlays = countdownOverlays { show(overlays); return }
                // Wait for real countdowns rather than drawing every block as
                // "7+ days" and then redrawing the whole city moments later.
                guard let entries = countdown?.entries else { return }
                build("countdown", layer: layer) {
                    StripeBuilder.countdownOverlays(for: segments, entries: entries)
                } store: { self.countdownOverlays = $0 }

            case .meters:
                if let overlays = meterOverlays { show(overlays); return }
                guard let entries = meters?.entries else { return }
                build("meters", layer: layer) {
                    StripeBuilder.meterOverlays(for: segments, entries: entries)
                } store: { self.meterOverlays = $0 }

            case .dots(let bucket):
                if let cache = dotCache, cache.bucket == bucket { show(cache.overlays); return }
                let mpp = pow(2, Double(bucket) / 2)
                build("dots", layer: layer) {
                    DotBuilder.overlays(for: segments, metersPerPoint: mpp)
                } store: { self.dotCache = (bucket, $0) }
            }
        }

        private func build(_ key: String, layer: MarkLayer,
                           _ make: @escaping @Sendable () -> [StripeOverlay],
                           store: @escaping ([StripeOverlay]) -> Void) {
            buildTasks[key]?.cancel()
            buildTasks[key] = Task { [weak self] in
                let overlays = await Task.detached(priority: .userInitiated) { make() }.value
                guard let self, !Task.isCancelled else { return }
                store(overlays)
                if self.layer == layer { self.show(overlays) }
            }
        }

        private func show(_ overlays: [StripeOverlay]) {
            guard let mapView else { return }
            mapView.removeOverlays(shownOverlays)
            shownOverlays = overlays
            // Above roads but below street-name labels, so names stay legible.
            mapView.addOverlays(overlays, level: .aboveRoads)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let stripe = overlay as? StripeOverlay else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKMultiPolylineRenderer(multiPolyline: stripe)
            renderer.strokeColor = stripe.color
            renderer.lineCap = .round
            renderer.lineJoin = .round
            if let dotDiameter = stripe.dotDiameter {
                renderer.lineWidth = dotDiameter
                renderer.alpha = 0.9
            } else {
                renderer.lineWidth = stripeWidth
                stripeRenderers.add(renderer)
            }
            return renderer
        }

        // MARK: Labels

        private func updateLabelStyle(mpp: Double, mapView: MKMapView) {
            // No pills while driving: the side cards carry the details.
            let style = isDriving ? nil : LabelStyle.forMetersPerPoint(mpp)
            guard style != labelStyle else { return }
            let wasVisible = labelStyle != nil
            labelStyle = style
            if let style {
                for view in allLabelViews(mapView) {
                    view.setStyle(style, content: labelContent(for: view.segment),
                                  heading: mapView.camera.heading)
                }
            }
            if wasVisible != (style != nil) {
                parent.onLabelsVisibleChange(style != nil)
                refreshLabels()
            }
            declutter()
        }

        private func labelContent(for segment: ParkingSegment?) -> LabelContent {
            guard let segment else { return .days }
            switch displayMode {
            case .days:      return .days
            case .countdown: return .countdown(countdown?.entries[segment.id])
            case .meters:    return .meter(MeterPill(meter: segment.meter, state: meters?.entries[segment.id]))
            }
        }

        /// Re-renders existing pills after the display mode or countdowns change.
        private func refreshLabelContent(_ mapView: MKMapView) {
            guard let style = labelStyle else { return }
            for view in allLabelViews(mapView) {
                view.setStyle(style, content: labelContent(for: view.segment),
                              heading: mapView.camera.heading)
            }
            declutter()
        }

        /// Keeps label annotations for the viewport (plus a margin) on the map.
        private func refreshLabels() {
            guard let mapView else { return }
            guard labelStyle != nil, let index else {
                if !labelAnnotations.isEmpty {
                    mapView.removeAnnotations(Array(labelAnnotations.values))
                    labelAnnotations = [:]
                }
                return
            }
            let visible = mapView.visibleMapRect
            let rect = visible.insetBy(dx: -visible.width * 0.5, dy: -visible.height * 0.5)
            var wanted: [String: ParkingSegment] = [:]
            for seg in index.segments(in: rect) where displayMode.shows(seg) { wanted[seg.id] = seg }

            let stale = labelAnnotations.filter { wanted[$0.key] == nil }
            if !stale.isEmpty {
                mapView.removeAnnotations(Array(stale.values))
                for id in stale.keys { labelAnnotations[id] = nil }
            }
            var added: [SegmentAnnotation] = []
            for (id, seg) in wanted where labelAnnotations[id] == nil {
                let a = SegmentAnnotation(segment: seg)
                labelAnnotations[id] = a
                added.append(a)
            }
            if !added.isEmpty { mapView.addAnnotations(added) }
        }

        private func allLabelViews(_ mapView: MKMapView) -> [SegmentLabelView] {
            labelAnnotations.values.compactMap { mapView.view(for: $0) as? SegmentLabelView }
        }

        private func visibleLabelViews(_ mapView: MKMapView) -> [SegmentLabelView] {
            let rect = mapView.visibleMapRect
            let padded = rect.insetBy(dx: -rect.width * 0.15, dy: -rect.height * 0.15)
            return mapView.annotations(in: padded).compactMap {
                ($0 as? SegmentAnnotation).flatMap { mapView.view(for: $0) as? SegmentLabelView }
            }
        }

        /// Hides labels that would overlap an already-placed one. Labels already on
        /// screen win ties, so panning and small zooms don't make labels flicker.
        private func declutter() {
            guard let mapView else { return }
            lastDeclutter = (metersPerPoint(mapView), mapView.camera.heading)
            let views = visibleLabelViews(mapView).sorted { a, b in
                if a.isShown != b.isShown { return a.isShown }
                if a.priority != b.priority { return a.priority > b.priority }
                return a.segmentID < b.segmentID
            }
            var placed: [OrientedRect] = []
            for view in views {
                guard let annotation = view.annotation else { continue }
                let center = mapView.convert(annotation.coordinate, toPointTo: mapView)
                let rect = OrientedRect(center: center, size: view.contentSize, angle: view.angle,
                                        margin: 3)
                if placed.contains(where: { $0.intersects(rect) }) {
                    view.setShown(false)
                } else {
                    placed.append(rect)
                    view.setShown(true)
                }
            }
        }

        private func scheduleDeclutter() {
            guard !declutterScheduled else { return }
            declutterScheduled = true
            DispatchQueue.main.async { [weak self] in
                self?.declutterScheduled = false
                self?.declutter()
            }
        }

        func mapView(_ mapView: MKMapView, didAdd views: [MKAnnotationView]) {
            if views.contains(where: { $0 is SegmentLabelView }) { scheduleDeclutter() }
        }

        // MARK: Annotation views

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            switch annotation {
            case let a as SegmentAnnotation:
                let view = mapView.dequeueReusableAnnotationView(
                    withIdentifier: SegmentLabelView.reuseID, for: a) as! SegmentLabelView
                view.configure(segment: a.segment, style: labelStyle ?? .small,
                               content: labelContent(for: a.segment),
                               heading: mapView.camera.heading)
                return view

            case let a as CarAnnotation:
                let view = CarAnnotationView(annotation: a, reuseIdentifier: nil)
                view.onTap = { [weak self] in self?.parent.onCarTap() }
                let pan = UIPanGestureRecognizer(target: self, action: #selector(handleCarPan(_:)))
                pan.delegate = self
                view.addGestureRecognizer(pan)
                carPan = pan
                return view

            default:
                return nil
            }
        }

        // MARK: Parked car

        private func syncCar() {
            guard let mapView else { return }
            guard let record = parkedRecord else {
                if let car = carAnnotation { mapView.removeAnnotation(car) }
                carAnnotation = nil
                return
            }
            if let car = carAnnotation {
                if carDrag == nil { car.coordinate = record.carCoordinate }
            } else {
                let car = CarAnnotation(coordinate: record.carCoordinate)
                carAnnotation = car
                mapView.addAnnotation(car)
            }
        }

        /// Drags the car along its block: the finger's position is projected onto
        /// the street axis and clamped to the block's length.
        @objc private func handleCarPan(_ gr: UIPanGestureRecognizer) {
            guard let mapView, let record = parkedRecord, let car = carAnnotation else { return }
            let finger = gr.location(in: mapView)
            switch gr.state {
            case .began:
                let carPoint = mapView.convert(car.coordinate, toPointTo: mapView)
                carDrag = (CGSize(width: finger.x - carPoint.x, height: finger.y - carPoint.y),
                           record.offsetMeters)
            case .changed:
                guard let drag = carDrag else { return }
                let target = CGPoint(x: finger.x - drag.grabOffset.width, y: finger.y - drag.grabOffset.height)
                let coord = mapView.convert(target, toCoordinateFrom: mapView)
                let limit = record.halfBlockLengthMeters
                let offset = max(-limit, min(limit, record.offset(of: coord)))
                carDrag?.offset = offset
                car.coordinate = record.coordinate(atOffset: offset)
            case .ended, .cancelled, .failed:
                guard let drag = carDrag else { return }
                carDrag = nil
                var offset = drag.offset
                // Keep the car clear of the block's center label.
                let clearance = 12.0
                if abs(offset) < clearance { offset = offset >= 0 ? clearance : -clearance }
                let limit = record.halfBlockLengthMeters
                offset = max(-limit, min(limit, offset))
                car.coordinate = record.coordinate(atOffset: offset)
                parent.onCarMoved(offset)
            default:
                break
            }
        }

        // MARK: Taps

        @objc private func handleMapTap(_ gr: UITapGestureRecognizer) {
            guard let mapView, gr.state == .ended else { return }
            let point = gr.location(in: mapView)

            // Taps on the car or user location belong to those views.
            var hit = mapView.hitTest(point, with: nil)
            while let v = hit {
                if v is MKAnnotationView, !(v is SegmentLabelView) { return }
                hit = v.superview
            }

            if let segment = labelSegment(at: point, in: mapView) ?? stripeSegment(at: point, in: mapView) {
                parent.onSelectSegment(segment)
            }
        }

        private func labelSegment(at point: CGPoint, in mapView: MKMapView) -> ParkingSegment? {
            for view in visibleLabelViews(mapView) where view.isShown {
                guard let annotation = view.annotation else { continue }
                let center = mapView.convert(annotation.coordinate, toPointTo: mapView)
                let rect = OrientedRect(center: center, size: view.contentSize, angle: view.angle, margin: 4)
                if rect.contains(point) { return view.segment }
            }
            return nil
        }

        /// Nearest curb stripe within a finger's width of the tap.
        private func stripeSegment(at point: CGPoint, in mapView: MKMapView) -> ParkingSegment? {
            guard let index else { return nil }
            let tolerance: CGFloat = 22
            let r = tolerance
            let a = mapView.convert(CGPoint(x: point.x - r, y: point.y - r), toCoordinateFrom: mapView)
            let b = mapView.convert(CGPoint(x: point.x + r, y: point.y + r), toCoordinateFrom: mapView)
            let c = mapView.convert(CGPoint(x: point.x - r, y: point.y + r), toCoordinateFrom: mapView)
            let d = mapView.convert(CGPoint(x: point.x + r, y: point.y - r), toCoordinateFrom: mapView)
            let lats = [a, b, c, d].map(\.latitude), lons = [a, b, c, d].map(\.longitude)
            let candidates = index.segments(minLat: lats.min()!, maxLat: lats.max()!,
                                            minLon: lons.min()!, maxLon: lons.max()!)
            var best: (ParkingSegment, CGFloat)?
            for seg in candidates where displayMode.shows(seg) {
                let pts = seg.curve.map { mapView.convert($0, toPointTo: mapView) }
                let dist = zip(pts, pts.dropFirst()).map { distance(point, $0, $1) }.min() ?? .infinity
                if dist <= tolerance, dist < (best?.1 ?? .infinity) { best = (seg, dist) }
            }
            return best?.0
        }

        // MARK: Gesture delegate

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            gestureRecognizer !== carPan
        }

        /// While a finger drags the car, the map's own pan/pinch wait for the car
        /// drag to fail, so the map doesn't scroll underneath it.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            gestureRecognizer === carPan && other.view !== gestureRecognizer.view
        }
    }
}

// MARK: - Stripes

/// A batch of same-colored curb stripes. Stripes are chunked spatially so MapKit
/// can skip chunks outside the viewport, but coarsely: each overlay carries real
/// per-overlay overhead, and thousands of them make swapping layers slow.
final class StripeOverlay: MKMultiPolyline {
    var color: UIColor = .gray
    /// Set for dot overlays: each polyline is a near-zero-length segment drawn
    /// with round caps at this width, i.e. a dot of this diameter.
    var dotDiameter: CGFloat?
}

enum StripeBuilder {
    private static let chunkDegrees = 0.08   // ≈ 9 km

    /// Stripe width tracks the real parking lane (~2.6 m) when zoomed in, with a
    /// floor so stripes stay visible zoomed out; hairlines at borough scale.
    static func lineWidth(metersPerPoint mpp: Double) -> CGFloat {
        let width = min(12, max(mpp > 8 ? 1.5 : 2.5, 2.6 / mpp))
        return CGFloat((width * 2).rounded() / 2)
    }

    /// One solid line per block, colored by days until the move. Greener lines are drawn last so
    /// long-term parking stands out where lines overlap at far zoom. Metered curbs are drawn in
    /// meter blue underneath, as everywhere in the app; their pills carry the countdown.
    static func countdownOverlays(for segments: [ParkingSegment],
                                  entries: [String: MoveCountdown]) -> [StripeOverlay] {
        struct Key: Hashable { let row: Int; let col: Int; let urgency: MoveUrgency?; }
        var groups: [Key: [MKPolyline]] = [:]
        for seg in segments where !seg.moveWindows.isEmpty && seg.curve.count >= 2 {
            let urgency = seg.meter == nil ? MoveUrgency(days: entries[seg.id]?.days) : nil
            let row = Int((seg.coordinate.latitude / chunkDegrees).rounded(.down))
            let col = Int((seg.coordinate.longitude / chunkDegrees).rounded(.down))
            groups[Key(row: row, col: col, urgency: urgency), default: []]
                .append(MKPolyline(coordinates: seg.curve, count: seg.curve.count))
        }
        return groups
            .sorted { ($0.key.urgency?.level ?? -1) < ($1.key.urgency?.level ?? -1) }
            .map { key, lines in
                let overlay = StripeOverlay(lines)
                overlay.color = key.urgency?.uiColor ?? meteredCurbColor
                return overlay
            }
    }

    /// Metered curbs in the countdown view: the same blue as paid meters.
    static let meteredCurbColor = MeterState.Kind.paid.uiColor

    /// One solid line per metered curb, colored by whether it's free, paid or
    /// commercial-only right now.
    static func meterOverlays(for segments: [ParkingSegment],
                              entries: [String: MeterState]) -> [StripeOverlay] {
        struct Key: Hashable { let row: Int; let col: Int; let kind: MeterState.Kind }
        var groups: [Key: [MKPolyline]] = [:]
        for seg in segments where seg.curve.count >= 2 {
            guard let kind = entries[seg.id]?.kind else { continue }
            let row = Int((seg.coordinate.latitude / chunkDegrees).rounded(.down))
            let col = Int((seg.coordinate.longitude / chunkDegrees).rounded(.down))
            groups[Key(row: row, col: col, kind: kind), default: []]
                .append(MKPolyline(coordinates: seg.curve, count: seg.curve.count))
        }
        return groups
            .sorted { $0.key.kind.rawValue > $1.key.kind.rawValue }   // free curbs on top
            .map { key, lines in
                let overlay = StripeOverlay(lines)
                overlay.color = key.kind.uiColor
                return overlay
            }
    }

    static func overlays(for segments: [ParkingSegment]) -> [StripeOverlay] {
        struct Key: Hashable { let row: Int; let col: Int; let day: ParkingDay }
        var groups: [Key: [MKPolyline]] = [:]
        for seg in segments {
            let days = seg.allDays
            guard !days.isEmpty else { continue }
            let row = Int((seg.coordinate.latitude / chunkDegrees).rounded(.down))
            let col = Int((seg.coordinate.longitude / chunkDegrees).rounded(.down))
            let pieces = split(seg.readingOrderCurve, into: days.count)
            for (day, piece) in zip(days, pieces) where piece.count >= 2 {
                groups[Key(row: row, col: col, day: day), default: []]
                    .append(MKPolyline(coordinates: piece, count: piece.count))
            }
        }
        // Add in weekday order so draw order (and cap overlap) is consistent.
        return groups
            .sorted { $0.key.day.sortOrder < $1.key.day.sortOrder }
            .map { key, lines in
                let overlay = StripeOverlay(lines)
                overlay.color = key.day.uiColor
                return overlay
            }
    }

    /// Splits a polyline into `n` consecutive pieces of equal length.
    static func split(_ curve: [CLLocationCoordinate2D], into n: Int) -> [[CLLocationCoordinate2D]] {
        guard n > 1, curve.count >= 2 else { return [curve] }
        let pts = curve.map { MKMapPoint($0) }
        var cumulative = [0.0]
        for (a, b) in zip(pts, pts.dropFirst()) { cumulative.append(cumulative.last! + a.distance(to: b)) }
        let total = cumulative.last!
        guard total > 0 else { return Array(repeating: curve, count: n) }

        func point(at s: Double) -> CLLocationCoordinate2D {
            var i = 1
            while i < cumulative.count - 1 && cumulative[i] < s { i += 1 }
            let span = cumulative[i] - cumulative[i - 1]
            let t = span > 0 ? (s - cumulative[i - 1]) / span : 0
            let p = MKMapPoint(x: pts[i - 1].x + (pts[i].x - pts[i - 1].x) * t,
                               y: pts[i - 1].y + (pts[i].y - pts[i - 1].y) * t)
            return p.coordinate
        }

        return (0..<n).map { k in
            let s0 = total * Double(k) / Double(n)
            let s1 = total * Double(k + 1) / Double(n)
            var piece = [point(at: s0)]
            for i in 1..<(cumulative.count - 1) where cumulative[i] > s0 && cumulative[i] < s1 {
                piece.append(curve[i])
            }
            piece.append(point(at: s1))
            return piece
        }
    }
}

/// Zoomed-out markers: a run of day-colored dots at each block's curb midpoint,
/// laid along the street (MON first, reading west→east / south→north).
enum DotBuilder {
    private static let chunkDegrees = 0.08

    /// Diameter shrinks as the map zooms out; dot runs collapse to one dot (the
    /// first day) at borough scale, where multi-dot runs would just smear.
    static func overlays(for segments: [ParkingSegment], metersPerPoint mpp: Double) -> [StripeOverlay] {
        let diameter = CGFloat(min(7, max(2, 7 * pow(1.6 / mpp, 0.5))).rounded())
        let collapse = mpp > 12
        let stepMeters = (Double(diameter) + max(1, Double(diameter) * 0.45)) * mpp

        struct Key: Hashable { let row: Int; let col: Int; let day: ParkingDay }
        var groups: [Key: [MKPolyline]] = [:]
        for seg in segments {
            var days = seg.allDays
            guard !days.isEmpty else { continue }
            if collapse { days = [days[0]] }
            let c = seg.coordinate
            var b = (seg.streetBearing ?? 90).truncatingRemainder(dividingBy: 180)
            if b < 0 { b += 180 }
            let rad = b * .pi / 180
            let mPerLat = 111_320.0, mPerLon = mPerLat * cos(c.latitude * .pi / 180)
            func point(_ m: Double) -> CLLocationCoordinate2D {
                CLLocationCoordinate2D(latitude: c.latitude + cos(rad) * m / mPerLat,
                                       longitude: c.longitude + sin(rad) * m / mPerLon)
            }
            let row = Int((c.latitude / chunkDegrees).rounded(.down))
            let col = Int((c.longitude / chunkDegrees).rounded(.down))
            let half = Double(days.count - 1) / 2
            for (i, day) in days.enumerated() {
                let m = (Double(i) - half) * stepMeters
                var pts = [point(m), point(m + 0.05)]
                groups[Key(row: row, col: col, day: day), default: []]
                    .append(MKPolyline(coordinates: &pts, count: 2))
            }
        }
        return groups
            .sorted { $0.key.day.sortOrder < $1.key.day.sortOrder }
            .map { key, dots in
                let overlay = StripeOverlay(dots)
                overlay.color = key.day.uiColor
                overlay.dotDiameter = diameter
                return overlay
            }
    }
}

// MARK: - Label annotation

final class SegmentAnnotation: NSObject, MKAnnotation {
    let segment: ParkingSegment
    let coordinate: CLLocationCoordinate2D

    init(segment: ParkingSegment) {
        self.segment = segment
        self.coordinate = segment.coordinate
    }
}

/// A day pill lying along its street. MapKit keeps annotation views upright, so we
/// rotate the pill ourselves whenever the map heading changes.
final class SegmentLabelView: MKAnnotationView {
    static let reuseID = "segmentLabel"

    private let imageView = UIImageView()
    private(set) var segment: ParkingSegment?
    private(set) var segmentID = ""
    private(set) var angle: CGFloat = 0
    private(set) var isShown = false
    /// The pill's size without its shadow margin (used for overlap and hit tests).
    private(set) var contentSize: CGSize = .zero
    /// Longer blocks win overlaps: they have more room and are usually avenues.
    private(set) var priority: Double = 0

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        canShowCallout = false
        collisionMode = .none
        displayPriority = .required
        zPriority = .min
        imageView.alpha = 0
        addSubview(imageView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func prepareForReuse() {
        super.prepareForReuse()
        isShown = false
        imageView.layer.removeAllAnimations()
        imageView.alpha = 0
    }

    @MainActor
    func configure(segment: ParkingSegment, style: LabelStyle, content: LabelContent, heading: Double) {
        self.segment = segment
        segmentID = segment.id
        priority = segment.halfBlockLengthMeters
        setStyle(style, content: content, heading: heading)
    }

    @MainActor
    func setStyle(_ style: LabelStyle, content: LabelContent, heading: Double) {
        guard let segment else { return }
        let image = ParkingLabelRenderer.image(for: segment, content: content, style: style)
        let pad = ParkingLabelRenderer.shadowPadding
        imageView.transform = .identity
        imageView.image = image
        imageView.frame = CGRect(origin: .zero, size: image.size)
        bounds = CGRect(origin: .zero, size: image.size)
        imageView.center = CGPoint(x: bounds.midX, y: bounds.midY)
        contentSize = CGSize(width: image.size.width - 2 * pad, height: image.size.height - 2 * pad)
        setHeading(heading)
    }

    func setHeading(_ heading: Double) {
        let bearing = segment?.streetBearing ?? 90
        var b = (bearing - heading).truncatingRemainder(dividingBy: 360)
        if b < 0 { b += 360 }
        // Keep text upright by folding into [−5°, 175°) rather than [0°, 180°):
        // labels on streets within a few degrees of vertical then all read
        // bottom-to-top, instead of flipping on 1° bearing differences when the
        // map is rotated to line a street grid up with the screen.
        if b >= 355 { b -= 360 } else if b >= 175 { b -= 180 }
        angle = CGFloat((b - 90) * .pi / 180)   // east = 0, north = −90°
        imageView.transform = CGAffineTransform(rotationAngle: angle)
    }

    func setShown(_ shown: Bool) {
        guard shown != isShown else { return }
        isShown = shown
        UIView.animate(withDuration: shown ? 0.2 : 0.12, delay: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.imageView.alpha = shown ? 1 : 0
        }
    }
}

// MARK: - Parked car

final class CarAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D

    init(coordinate: CLLocationCoordinate2D) { self.coordinate = coordinate }
}

final class CarAnnotationView: MKAnnotationView {
    var onTap: (() -> Void)?

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 36, height: 36)
        collisionMode = .none
        displayPriority = .required
        zPriority = .max
        canShowCallout = false

        let circle = UIView(frame: bounds)
        circle.backgroundColor = .systemBlue
        circle.layer.cornerRadius = 18
        circle.layer.shadowColor = UIColor.black.cgColor
        circle.layer.shadowOpacity = 0.25
        circle.layer.shadowRadius = 4
        circle.layer.shadowOffset = CGSize(width: 0, height: 2)
        circle.isUserInteractionEnabled = false
        addSubview(circle)

        let icon = UIImageView(image: UIImage(systemName: "car.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)))
        icon.tintColor = .white
        icon.center = CGPoint(x: bounds.midX, y: bounds.midY)
        circle.addSubview(icon)

        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func tapped() { onTap?() }
}

// MARK: - Geometry helpers

/// A screen-space rectangle rotated about its center, for label overlap tests.
struct OrientedRect {
    let center: CGPoint
    let halfWidth: CGFloat
    let halfHeight: CGFloat
    let axisX: CGVector
    let axisY: CGVector

    init(center: CGPoint, size: CGSize, angle: CGFloat, margin: CGFloat) {
        self.center = center
        halfWidth = size.width / 2 + margin
        halfHeight = size.height / 2 + margin
        axisX = CGVector(dx: cos(angle), dy: sin(angle))
        axisY = CGVector(dx: -sin(angle), dy: cos(angle))
    }

    func contains(_ p: CGPoint) -> Bool {
        let dx = p.x - center.x, dy = p.y - center.y
        return abs(dx * axisX.dx + dy * axisX.dy) <= halfWidth
            && abs(dx * axisY.dx + dy * axisY.dy) <= halfHeight
    }

    /// Separating-axis test.
    func intersects(_ o: OrientedRect) -> Bool {
        let dx = o.center.x - center.x, dy = o.center.y - center.y
        // Quick reject on bounding circles.
        let r1 = hypot(halfWidth, halfHeight), r2 = hypot(o.halfWidth, o.halfHeight)
        if dx * dx + dy * dy > (r1 + r2) * (r1 + r2) { return false }
        for axis in [axisX, axisY, o.axisX, o.axisY] {
            let dist = abs(dx * axis.dx + dy * axis.dy)
            let ra = projectedRadius(on: axis), rb = o.projectedRadius(on: axis)
            if dist > ra + rb { return false }
        }
        return true
    }

    private func projectedRadius(on axis: CGVector) -> CGFloat {
        halfWidth * abs(axisX.dx * axis.dx + axisX.dy * axis.dy)
            + halfHeight * abs(axisY.dx * axis.dx + axisY.dy * axis.dy)
    }
}

/// Distance from point p to segment ab.
private func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
    let abx = b.x - a.x, aby = b.y - a.y
    let len2 = abx * abx + aby * aby
    let t = len2 > 0 ? max(0, min(1, ((p.x - a.x) * abx + (p.y - a.y) * aby) / len2)) : 0
    return hypot(p.x - (a.x + t * abx), p.y - (a.y + t * aby))
}

/// Signed smallest difference between two headings, in degrees.
private func angleDelta(_ a: Double, _ b: Double) -> Double {
    var d = (a - b).truncatingRemainder(dividingBy: 360)
    if d > 180 { d -= 360 }
    if d < -180 { d += 360 }
    return d
}
