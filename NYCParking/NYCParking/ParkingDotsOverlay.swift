import SwiftUI
import MapKit

/// Renders parking-restriction dots by injecting a ParkingDotsView directly into
/// MKMapView's subview hierarchy at the index just before MapKit's annotation layer.
/// This lets UserAnnotation and other MapKit annotations sit naturally above the dots
/// without any duplicate markers.
struct MapDotsLayer: UIViewRepresentable {
    let segments: [ParkingSegment]
    let region: MKCoordinateRegion?

    func makeUIView(context: Context) -> UIView {
        // A hidden placeholder — the real canvas lives inside MKMapView.
        let v = UIView()
        v.isHidden = true
        v.isUserInteractionEnabled = false
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.update(segments: segments, region: region)
        context.coordinator.installIfNeeded(from: uiView)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        let canvas = ParkingDotsView()
        private var installed = false

        init() {
            canvas.backgroundColor = .clear
            canvas.isOpaque = false
            canvas.isUserInteractionEnabled = false
        }

        deinit { canvas.removeFromSuperview() }

        func update(segments: [ParkingSegment], region: MKCoordinateRegion?) {
            canvas.segments = segments
            canvas.region = region
            canvas.setNeedsDisplay()
        }

        func installIfNeeded(from placeholder: UIView) {
            guard !installed else { return }
            // Walk to UIWindow, then search down for MKMapView.
            var root: UIView = placeholder
            while let p = root.superview { root = p }
            guard let mapView = findMKMapView(in: root) else { return }

            canvas.frame = mapView.bounds
            canvas.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            mapView.insertSubview(canvas, at: annotationLayerIndex(in: mapView))
            installed = true
        }

        private func findMKMapView(in view: UIView, depth: Int = 0) -> MKMapView? {
            guard depth < 25 else { return nil }
            if let mv = view as? MKMapView { return mv }
            for sub in view.subviews {
                if let found = findMKMapView(in: sub, depth: depth + 1) { return found }
            }
            return nil
        }

        /// Returns the insertion index just before MapKit's annotation container,
        /// so dots appear above map tiles but below annotation/user-location views.
        private func annotationLayerIndex(in mapView: MKMapView) -> Int {
            for (i, sub) in mapView.subviews.enumerated() {
                let name = String(describing: type(of: sub))
                if name.contains("Annotation") || name.contains("UserLocation") {
                    return i
                }
            }
            return max(0, mapView.subviews.count - 1)
        }
    }
}

// MARK: - Canvas

final class ParkingDotsView: UIView {
    var segments: [ParkingSegment] = []
    var region: MKCoordinateRegion?

    override func draw(_ rect: CGRect) {
        guard let region, !segments.isEmpty,
              let ctx = UIGraphicsGetCurrentContext() else { return }

        let w = Double(bounds.width)
        let h = Double(bounds.height)
        let dotR = dotRadius(for: region.span.latitudeDelta)

        let minLon = region.center.longitude - region.span.longitudeDelta / 2.0
        let lonRange = region.span.longitudeDelta

        // Mercator Y for accurate vertical placement (matches MapKit's projection)
        func mercY(_ lat: Double) -> Double {
            let rad = lat * .pi / 180.0
            return log(tan(.pi / 4.0 + rad / 2.0))
        }
        let maxMercY = mercY(region.center.latitude + region.span.latitudeDelta / 2.0)
        let mercRange = maxMercY - mercY(region.center.latitude - region.span.latitudeDelta / 2.0)
        guard lonRange > 0, mercRange > 0 else { return }

        // Build one path per day color — drops ~50k fill calls to at most 8.
        // Multi-day segments draw N side-by-side circles (matching ParkingLabel.dotView).
        let gap = max(1.0, dotR * 0.43)
        let step = dotR * 2 + gap
        var paths: [ParkingDay: CGMutablePath] = [:]
        for seg in segments {
            let days = seg.allDays
            guard !days.isEmpty else { continue }
            let coord = seg.sidewalkCoordinate
            let px = (coord.longitude - minLon) / lonRange * w
            let py = (maxMercY - mercY(coord.latitude)) / mercRange * h
            guard px >= -dotR * Double(days.count) * 2, px <= w + dotR * Double(days.count) * 2,
                  py >= -dotR, py <= h + dotR else { continue }
            // Center the group of N dots around (px, py)
            let startX = px - (Double(days.count) - 1) * step / 2
            for (i, day) in days.enumerated() {
                let cx = startX + Double(i) * step
                guard cx >= -dotR, cx <= w + dotR else { continue }
                if paths[day] == nil { paths[day] = CGMutablePath() }
                paths[day]!.addEllipse(in: CGRect(x: cx - dotR, y: py - dotR,
                                                   width: dotR * 2, height: dotR * 2))
            }
        }

        for (day, path) in paths {
            ctx.setFillColor(UIColor(day.color).withAlphaComponent(0.85).cgColor)
            ctx.addPath(path)
            ctx.fillPath()
        }
    }

    // Dot radius shrinks in threshold steps as the map zooms out.
    private func dotRadius(for latDelta: Double) -> Double {
        switch latDelta {
        case ..<0.010: return 3.5
        case ..<0.025: return 2.5
        case ..<0.06:  return 2.0
        case ..<0.15:  return 1.5
        case ..<0.35:  return 1.0
        default:       return 0.6
        }
    }
}
