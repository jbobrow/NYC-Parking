import SwiftUI
import MapKit
import QuartzCore
import CoreMotion

// MARK: - Street matching

/// The block you're driving along and the parking rules on each side of you.
struct DriveMatch: Equatable {
    let blockID: String
    let street: String
    /// Cross streets in your direction of travel.
    let fromStreet: String
    let toStreet: String
    let left: ParkingSegment?
    let right: ParkingSegment?
    /// The block past the next intersection, shown as you approach it.
    let isUpcoming: Bool
}

/// Works out which block you're driving along and which of its block faces are
/// on your left and right.
///
/// Block faces come in pairs that share a centerline block: ids "<block>L" and
/// "<block>R", both stored running in the centerline's direction, with L on its
/// left. Driving with the centerline, L is on your left; driving against it, the
/// sides swap.
@MainActor
final class DriveMatcher {
    private struct Hit {
        let blockID: String
        let distance: Double
        /// Centerline direction at your position, degrees clockwise from north.
        let tangent: Double
        /// Meters from the centerline start, and the block's length.
        let along: Double
        let length: Double
    }

    private static let maxDistance = 32.0      // curb offset on a wide avenue plus GPS error
    private static let maxAngle = 35.0         // how far off the street's direction you can be heading
    private static let keepMargin = 8.0        // hysteresis: a new block must be clearly closer
    private static let previewDistance = 35.0  // start previewing the next block this far out

    private var current: (hit: Hit, forward: Bool)?

    /// The street's direction of travel at your position, for steadying the camera.
    var streetBearing: Double? {
        current.map { $0.forward ? $0.hit.tangent : normalize($0.hit.tangent + 180) }
    }

    func reset() { current = nil }

    /// - Parameter course: direction of travel, or nil when stopped (keeps the current block).
    func match(position: CLLocationCoordinate2D, course: Double?, speed: Double,
               index: SegmentIndex) -> DriveMatch? {
        let hits = candidates(near: position, course: course, index: index)
        let kept = current.flatMap { cur in hits.first { $0.blockID == cur.hit.blockID } }

        if let course {
            if let best = hits.first {
                let pick = (kept.map { $0.distance <= best.distance + Self.keepMargin } ?? false) ? kept! : best
                current = (pick, cos((course - pick.tangent) * .pi / 180) > 0)
            } else {
                current = nil
            }
        } else if let kept, let cur = current {
            current = (kept, cur.forward)   // stopped: stay on the block, keep the direction
        } else if current != nil, kept == nil {
            current = nil
        }

        guard let (hit, forward) = current else { return nil }

        // Approaching the end of the block: preview the next one.
        let remaining = forward ? hit.length - hit.along : hit.along
        if let course, speed > 2, remaining < Self.previewDistance {
            let travel = forward ? hit.tangent : normalize(hit.tangent + 180)
            let ahead = offset(position, meters: remaining + 20, bearing: travel)
            if let next = candidates(near: ahead, course: travel, index: index)
                .first(where: { $0.blockID != hit.blockID }) {
                let nextForward = cos((course - next.tangent) * .pi / 180) > 0
                return makeMatch(next, forward: nextForward, upcoming: true, index: index)
            }
        }
        return makeMatch(hit, forward: forward, upcoming: false, index: index)
    }

    private func makeMatch(_ hit: Hit, forward: Bool, upcoming: Bool, index: SegmentIndex) -> DriveMatch {
        let l = index.segment(id: hit.blockID + "L"), r = index.segment(id: hit.blockID + "R")
        let ref = l ?? r
        return DriveMatch(blockID: hit.blockID,
                          street: ref?.street ?? "",
                          fromStreet: (forward ? ref?.fromStreet : ref?.toStreet) ?? "",
                          toStreet: (forward ? ref?.toStreet : ref?.fromStreet) ?? "",
                          left: forward ? l : r,
                          right: forward ? r : l,
                          isUpcoming: upcoming)
    }

    /// Nearby blocks running roughly along `course`, closest first.
    private func candidates(near p: CLLocationCoordinate2D, course: Double?,
                            index: SegmentIndex) -> [Hit] {
        let box = 0.0005   // ≈ 55 m
        let point = MKMapPoint(p)
        let mppm = MKMetersPerMapPointAtLatitude(p.latitude)
        var best: [String: Hit] = [:]
        for seg in index.segments(minLat: p.latitude - box, maxLat: p.latitude + box,
                                  minLon: p.longitude - box, maxLon: p.longitude + box) {
            guard let proj = project(point, onto: seg.curve, metersPerMapPoint: mppm),
                  proj.distance <= Self.maxDistance else { continue }
            if let course {
                var diff = abs(angleDelta(course, proj.tangent))
                if diff > 90 { diff = 180 - diff }   // either direction along the street
                guard diff <= Self.maxAngle else { continue }
            }
            let blockID = String(seg.id.dropLast())
            let hit = Hit(blockID: blockID, distance: proj.distance, tangent: proj.tangent,
                          along: proj.along, length: proj.length)
            if best[blockID].map({ hit.distance < $0.distance }) ?? true { best[blockID] = hit }
        }
        return best.values.sorted { $0.distance < $1.distance }
    }
}

/// Distance from a point to a polyline, where along it the nearest point is, and
/// the polyline's direction there. Works in local meters.
private func project(_ p: MKMapPoint, onto curve: [CLLocationCoordinate2D], metersPerMapPoint mppm: Double)
    -> (distance: Double, along: Double, length: Double, tangent: Double)? {
    guard curve.count >= 2 else { return nil }
    let pts = curve.map { MKMapPoint($0) }
    var best: (distance: Double, along: Double, tangent: Double)?
    var run = 0.0
    for (a, b) in zip(pts, pts.dropFirst()) {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { continue }
        let len = len2.squareRoot()
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        let d = hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy)) * mppm
        if best == nil || d < best!.distance {
            // Map points grow east (x) and south (y).
            let tangent = normalize(atan2(dx, -dy) * 180 / .pi)
            best = (d, (run + t * len) * mppm, tangent)
        }
        run += len
    }
    guard let best else { return nil }
    return (best.distance, best.along, run * mppm, best.tangent)
}

// MARK: - Camera and puck

/// Drives the 3D camera in drive mode. Moves every screen frame rather than every
/// GPS fix: between fixes it predicts where the car is from its speed and course,
/// and it smooths position, heading and zoom so the map glides instead of
/// jumping once a second. When you're on a known street, the camera's heading
/// locks to the street's direction, which removes GPS heading wobble.
@MainActor
final class DriveController {
    weak var mapView: MKMapView?
    var index: () -> SegmentIndex? = { nil }
    var onMatch: (DriveMatch?) -> Void = { _ in }
    var onFollowChange: (Bool) -> Void = { _ in }

    private(set) var isActive = false
    private(set) var isFollowing = true

    private static let pitch = 60.0
    private static let positionTau = 0.35     // seconds; position smoothing
    private static let courseTau = 0.35
    private static let headingTau = 0.6
    private static let zoomTau = 1.5
    private static let blendDuration = 0.9
    private static let movingSpeed = 1.5      // m/s; below this, hold heading
    private static let staleFixAge = 3.0      // seconds
    /// How far ahead of the car to aim the camera (as a fraction of camera
    /// distance), so the car sits in the lower third with the road ahead in view.
    private static let aheadFactor = 0.15

    private var link: CADisplayLink?
    private let puck = DrivePuckView()
    private let matcher = DriveMatcher()

    private struct Fix {
        let coordinate: CLLocationCoordinate2D
        let time: CFTimeInterval
        let speed: Double
        let course: Double?
    }
    private var fix: Fix?
    private var previousLocation: CLLocation?

    private var shown: MKMapPoint?
    private var heading = 0.0
    private var travelCourse: Double?
    private var distance = 420.0
    private var lastTick: CFTimeInterval = 0
    private var lastMatchTime: CFTimeInterval = 0
    private var lastMatch: DriveMatch?
    private var blend: (from: MKMapCamera, start: CFTimeInterval)?

    func start() {
        guard !isActive, let mapView else { return }
        isActive = true
        isFollowing = true
        heading = mapView.camera.heading
        mapView.addSubview(puck)
        puck.isHidden = true
        blend = (mapView.camera.copy() as! MKMapCamera, CACurrentMediaTime())
        let link = CADisplayLink(target: DisplayLinkProxy(self), selector: #selector(DisplayLinkProxy.tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.link = link
        lastTick = CACurrentMediaTime()
        onFollowChange(true)
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        link?.invalidate()
        link = nil
        puck.removeFromSuperview()
        fix = nil
        previousLocation = nil
        shown = nil
        travelCourse = nil
        blend = nil
        matcher.reset()
        lastMatch = nil
        onMatch(nil)
    }

    /// The user moved the map: stop following until they re-center.
    func pause() {
        guard isActive, isFollowing else { return }
        isFollowing = false
        blend = nil
        onFollowChange(false)
    }

    func resume() {
        guard isActive, let mapView else { return }
        if !isFollowing {
            isFollowing = true
            blend = (mapView.camera.copy() as! MKMapCamera, CACurrentMediaTime())
            onFollowChange(true)
        }
    }

    func ingest(_ location: CLLocation) {
        guard isActive, location.horizontalAccuracy >= 0, location.horizontalAccuracy < 100 else { return }
        var speed = location.speed
        var course: Double? = location.course >= 0 ? location.course : nil
        // Some fixes (and simulated routes) lack speed or course: derive them.
        if speed < 0 || course == nil, let prev = previousLocation {
            let dt = location.timestamp.timeIntervalSince(prev.timestamp)
            let d = location.distance(from: prev)
            if dt > 0.2, d > 1 {
                if speed < 0 { speed = d / dt }
                if course == nil { course = bearing(from: prev.coordinate, to: location.coordinate) }
            }
        }
        previousLocation = location
        speed = max(speed, 0)

        // Timestamp the fix by when it was measured, not when it arrived.
        let age = min(max(Date().timeIntervalSince(location.timestamp), 0), 1)
        let newFix = Fix(coordinate: location.coordinate, time: CACurrentMediaTime() - age,
                         speed: speed, course: speed >= Self.movingSpeed ? course : nil)
        fix = newFix

        // First fix, or a jump no smoothing should hide: snap.
        let point = MKMapPoint(location.coordinate)
        if shown == nil || shown!.distance(to: point) > 150 {
            shown = point
            if let c = newFix.course { heading = c; travelCourse = c }
        }
    }

    fileprivate func tick() {
        let now = CACurrentMediaTime()
        let dt = min(max(now - lastTick, 1.0 / 240), 0.1)
        lastTick = now
        guard let mapView, var fix, var shown else { return }
        // No fix for a while (lost signal, or a replayed route ended): treat the
        // car as stopped rather than carrying the last speed forward.
        if now - fix.time > Self.staleFixAge {
            fix = Fix(coordinate: fix.coordinate, time: fix.time, speed: 0, course: nil)
        }
        let mppm = MKMetersPerMapPointAtLatitude(fix.coordinate.latitude)

        // Where the car should be now: the last fix, carried forward along its
        // course. Leading by the smoothing time constant cancels the lag the
        // smoothing below would otherwise add.
        var target = MKMapPoint(fix.coordinate)
        if let course = fix.course {
            let t = min(now - fix.time, 1.5) + Self.positionTau
            target = offset(target, meters: fix.speed * t, bearing: course, metersPerMapPoint: mppm)
        }
        let a = 1 - exp(-dt / Self.positionTau)
        shown = MKMapPoint(x: shown.x + (target.x - shown.x) * a, y: shown.y + (target.y - shown.y) * a)
        self.shown = shown

        if let course = fix.course {
            travelCourse = travelCourse.map { smoothAngle($0, course, 1 - exp(-dt / Self.courseTau)) } ?? course
        } else if fix.speed < Self.movingSpeed {
            travelCourse = nil
        }

        if now - lastMatchTime > 0.2, let index = index() {
            lastMatchTime = now
            let match = matcher.match(position: shown.coordinate, course: travelCourse,
                                      speed: fix.speed, index: index)
            if match != lastMatch {
                lastMatch = match
                onMatch(match)
            }
        }

        // Heading: lock to the street when we're clearly driving along it.
        var targetHeading = travelCourse ?? heading
        if let street = matcher.streetBearing, let course = travelCourse,
           abs(angleDelta(street, course)) < 20 {
            targetHeading = street
        }
        heading = smoothAngle(heading, targetHeading, 1 - exp(-dt / Self.headingTau))

        // Zoom out with speed so there's more road ahead at higher speeds.
        let speedFactor = min(max((fix.speed - 3) / 12, 0), 1)
        let targetDistance = 380 + 320 * speedFactor
        distance += (targetDistance - distance) * (1 - exp(-dt / Self.zoomTau))

        if isFollowing {
            let center = offset(shown, meters: distance * Self.aheadFactor, bearing: heading,
                                metersPerMapPoint: mppm).coordinate
            var camera = MKMapCamera(lookingAtCenter: center, fromDistance: distance,
                                     pitch: Self.pitch, heading: heading)
            if let blend {
                let t = (now - blend.start) / Self.blendDuration
                if t >= 1 {
                    self.blend = nil
                } else {
                    camera = interpolate(blend.from, camera, easeInOut(t))
                }
            }
            mapView.camera = camera
        }

        let screen = mapView.convert(shown.coordinate, toPointTo: mapView)
        puck.isHidden = false
        puck.update(center: screen, rotation: heading - mapView.camera.heading,
                    tilt: mapView.camera.pitch)
    }
}

/// Breaks the retain cycle between CADisplayLink and its target.
private final class DisplayLinkProxy {
    weak var controller: DriveController?
    init(_ controller: DriveController) { self.controller = controller }
    @MainActor @objc func tick() { controller?.tick() }
}

/// The car marker in drive mode: a navigation arrow lying flat on the road,
/// tilted with the camera so it reads as part of the 3D scene.
final class DrivePuckView: UIView {
    private let disc = CALayer()

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        isUserInteractionEnabled = false

        disc.frame = bounds
        disc.shadowColor = UIColor.black.cgColor
        disc.shadowOpacity = 0.35
        disc.shadowRadius = 5
        disc.shadowOffset = CGSize(width: 0, height: 2)
        layer.addSublayer(disc)

        let circle = CAShapeLayer()
        circle.path = UIBezierPath(ovalIn: bounds.insetBy(dx: 5, dy: 5)).cgPath
        circle.fillColor = UIColor.systemBlue.cgColor
        circle.strokeColor = UIColor.white.cgColor
        circle.lineWidth = 3
        disc.addSublayer(circle)

        let arrow = CAShapeLayer()
        let path = UIBezierPath()
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        path.move(to: CGPoint(x: c.x, y: c.y - 10))
        path.addLine(to: CGPoint(x: c.x + 8, y: c.y + 9))
        path.addLine(to: CGPoint(x: c.x, y: c.y + 5))
        path.addLine(to: CGPoint(x: c.x - 8, y: c.y + 9))
        path.close()
        arrow.path = path.cgPath
        arrow.fillColor = UIColor.white.cgColor
        disc.addSublayer(arrow)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// - Parameters:
    ///   - rotation: heading relative to the map's heading, in degrees.
    ///   - tilt: camera pitch, in degrees.
    func update(center: CGPoint, rotation: Double, tilt: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.center = center
        var t = CATransform3DIdentity
        t.m34 = -1 / 300
        t = CATransform3DRotate(t, CGFloat(tilt * 0.85 * .pi / 180), 1, 0, 0)
        t = CATransform3DRotate(t, CGFloat(rotation * .pi / 180), 0, 0, 1)
        disc.transform = t
        CATransaction.commit()
    }
}

// MARK: - Heads-up display

/// Drive mode's on-screen guidance: the street you're on, and a large card for
/// the parking rules on each side of you. Built to be read at a glance.
struct DriveHUD: View {
    let match: DriveMatch?
    let holidays: [NamedHoliday]

    var body: some View {
        TimelineView(.everyMinute) { _ in
            let calendar = CountdownCalendar { date in
                holidays.contains { Calendar.current.isDate($0.date, inSameDayAs: date) }
            }
            VStack(spacing: 8) {
                header
                if let match {
                    HStack(alignment: .top, spacing: 8) {
                        SideCard(side: .left, segment: match.left, calendar: calendar)
                        SideCard(side: .right, segment: match.right, calendar: calendar)
                    }
                    .id(match.blockID)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                }
            }
            .animation(.easeInOut(duration: 0.25), value: match?.blockID)
        }
    }

    private var header: some View {
        VStack(spacing: 2) {
            if let match {
                if match.isUpcoming {
                    Text("NEXT BLOCK")
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Text(StreetName.short(match.street))
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                let cross = [match.fromStreet, match.toStreet].filter { !$0.isEmpty }.map(StreetName.short)
                if !cross.isEmpty {
                    Text(cross.joined(separator: " → "))
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            } else {
                Text("Finding your street…")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
        .modifier(GlassRoundedBackground())
        .accessibilityElement(children: .combine)
    }
}

private struct SideCard: View {
    enum Side { case left, right }

    let side: Side
    let segment: ParkingSegment?
    let calendar: CountdownCalendar

    var body: some View {
        let countdown = segment.flatMap { MoveCountdown.next(for: $0.rules, in: calendar) }
        let urgency = segment.map { _ in MoveUrgency(days: countdown?.days) }
        let (title, detail) = texts(countdown)

        VStack(alignment: side == .left ? .leading : .trailing, spacing: 2) {
            HStack(spacing: 4) {
                if side == .left { Image(systemName: "arrow.left") }
                Text(side == .left ? "LEFT" : "RIGHT")
                if side == .right { Image(systemName: "arrow.right") }
            }
            .font(.system(size: 11, weight: .heavy, design: .rounded))
            .opacity(0.75)

            Text(title)
                .font(.system(size: 26, weight: .heavy, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(detail)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .foregroundStyle(urgency?.textColor ?? .primary)
        .frame(maxWidth: .infinity, alignment: side == .left ? .leading : .trailing)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background {
            if let urgency {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(urgency.color)
            }
        }
        .modifier(GlassRoundedBackground(enabled: urgency == nil))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(side == .left ? "Left" : "Right") side: \(title), \(detail)")
    }

    private func texts(_ c: MoveCountdown?) -> (String, String) {
        guard segment != nil else { return ("NO RULES", "No posted cleaning") }
        guard let c else { return ("7+ DAYS", "No cleaning this week") }
        if c.isUnderway {
            return ("NOW", c.endMinutes.map { "Until \(ParkingTime.format(minutes: $0 % (24 * 60)))" } ?? "Cleaning now")
        }
        let day = c.weekday.short.capitalized
        return (MoveCountdown.shortText(c), "\(day) \(ParkingTime.formatRange(c.startMinutes, c.endMinutes))")
    }
}

private struct GlassRoundedBackground: ViewModifier {
    var enabled = true

    func body(content: Content) -> some View {
        if !enabled {
            content
        } else if #available(iOS 26, *) {
            content.glassEffect(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else {
            content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }
}

/// Short, glanceable street names: "EAST 19 STREET" → "E 19th St".
enum StreetName {
    private static let words = [
        "Street": "St", "Avenue": "Ave", "Place": "Pl", "Boulevard": "Blvd", "Road": "Rd",
        "Parkway": "Pkwy", "Drive": "Dr", "Lane": "Ln", "Court": "Ct", "Terrace": "Ter",
        "Square": "Sq", "Expressway": "Expy", "Highway": "Hwy",
    ]
    private static let directions = ["East": "E", "West": "W", "North": "N", "South": "S"]

    static func short(_ name: String) -> String {
        var tokens = name.split(separator: " ").map { String($0).localizedCapitalized }
        if tokens.count > 1, let d = directions[tokens[0]] { tokens[0] = d }
        for i in tokens.indices {
            if let w = words[tokens[i]] { tokens[i] = w }
        }
        // "19 St" → "19th St"
        for i in tokens.indices.dropLast() where Int(tokens[i]) != nil && words.values.contains(tokens[i + 1]) {
            tokens[i] += ordinalSuffix(Int(tokens[i])!)
        }
        return tokens.joined(separator: " ")
    }

    private static func ordinalSuffix(_ n: Int) -> String {
        if (11...13).contains(n % 100) { return "th" }
        switch n % 10 {
        case 1: return "st"
        case 2: return "nd"
        case 3: return "rd"
        default: return "th"
        }
    }
}

// MARK: - Driving detection

/// Notices when you're driving, so the app can offer drive mode.
///
/// Uses the motion coprocessor's activity classification (which recognizes being
/// in a vehicle from its motion, even in slow traffic), confirmed by GPS showing
/// you've actually been moving recently, so sitting in a parked car doesn't count.
/// Without motion access, falls back to sustained driving speed.
@MainActor
final class DriveDetector: ObservableObject {
    @Published private(set) var isLikelyDriving = false

    private let activity = CMMotionActivityManager()
    private var isRunning = false
    private var inVehicle = false
    private var lastMovingAt: Date?
    private var fastSince: Date?

    private static let movingSpeed = 4.0          // m/s (≈ 9 mph): clearly not walking
    private static let recentWindow = 180.0       // seconds: a long light doesn't end a drive
    private static let fallbackSpeed = 8.0        // m/s (≈ 18 mph), sustained, without motion data
    private static let fallbackDuration = 20.0    // seconds

    /// Only once allowed (asked during onboarding), so detection never triggers
    /// a permission prompt of its own.
    private var motionUsable: Bool {
        CMMotionActivityManager.isActivityAvailable()
            && CMMotionActivityManager.authorizationStatus() == .authorized
    }

    /// Shows the Motion & Fitness permission prompt; returns whether it was granted.
    func requestMotionAccess() async -> Bool {
        guard CMMotionActivityManager.isActivityAvailable() else { return false }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let now = Date()
            activity.queryActivityStarting(from: now.addingTimeInterval(-60), to: now, to: .main) { _, _ in
                done.resume()
            }
        }
        let granted = CMMotionActivityManager.authorizationStatus() == .authorized
        if granted, isRunning {
            stop()
            start()
        }
        return granted
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        if motionUsable {
            activity.startActivityUpdates(to: .main) { [weak self] a in
                guard let self, let a else { return }
                self.inVehicle = a.automotive && a.confidence != .low
                self.evaluate()
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        activity.stopActivityUpdates()
        inVehicle = false
        isLikelyDriving = false
    }

    func ingest(_ location: CLLocation) {
        let now = Date()
        if location.speed >= Self.movingSpeed { lastMovingAt = now }
        if location.speed >= Self.fallbackSpeed {
            if fastSince == nil { fastSince = now }
        } else {
            fastSince = nil
        }
        evaluate()
    }

    private func evaluate() {
        guard isRunning else { return }
        let now = Date()
        let driving: Bool
        if motionUsable {
            let recentlyMoving = lastMovingAt.map { now.timeIntervalSince($0) < Self.recentWindow } ?? false
            driving = inVehicle && recentlyMoving
        } else {
            driving = fastSince.map { now.timeIntervalSince($0) >= Self.fallbackDuration } ?? false
        }
        if driving != isLikelyDriving { isLikelyDriving = driving }
    }
}

/// "Driving? Switch to drive mode" — a banner rather than an alert, so it never
/// blocks the map while you're on the road.
struct DrivePrompt: View {
    let onAccept: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "steeringwheel")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.blue)
            Text("Driving?")
                .font(.system(size: 16, weight: .bold, design: .rounded))
            Spacer(minLength: 4)
            Button("Not now", action: onDismiss)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(minHeight: 44)
                .padding(.horizontal, 6)
            Button(action: onAccept) {
                Text("Drive mode")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 40)
                    .background(Color.blue, in: Capsule())
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .modifier(GlassRoundedBackground())
    }
}

// MARK: - Geometry helpers

private func normalize(_ degrees: Double) -> Double {
    let d = degrees.truncatingRemainder(dividingBy: 360)
    return d < 0 ? d + 360 : d
}

/// Signed smallest difference a − b, in degrees (−180…180).
private func angleDelta(_ a: Double, _ b: Double) -> Double {
    var d = (a - b).truncatingRemainder(dividingBy: 360)
    if d > 180 { d -= 360 }
    if d < -180 { d += 360 }
    return d
}

private func smoothAngle(_ from: Double, _ to: Double, _ amount: Double) -> Double {
    normalize(from + angleDelta(to, from) * amount)
}

private func bearing(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
    let pa = MKMapPoint(a), pb = MKMapPoint(b)
    return normalize(atan2(pb.x - pa.x, -(pb.y - pa.y)) * 180 / .pi)
}

private func offset(_ p: MKMapPoint, meters: Double, bearing: Double, metersPerMapPoint mppm: Double) -> MKMapPoint {
    let r = bearing * .pi / 180
    let d = meters / mppm
    return MKMapPoint(x: p.x + sin(r) * d, y: p.y - cos(r) * d)
}

private func offset(_ c: CLLocationCoordinate2D, meters: Double, bearing: Double) -> CLLocationCoordinate2D {
    offset(MKMapPoint(c), meters: meters, bearing: bearing,
           metersPerMapPoint: MKMetersPerMapPointAtLatitude(c.latitude)).coordinate
}

private func easeInOut(_ t: Double) -> Double { t * t * (3 - 2 * t) }

private func interpolate(_ a: MKMapCamera, _ b: MKMapCamera, _ t: Double) -> MKMapCamera {
    let pa = MKMapPoint(a.centerCoordinate), pb = MKMapPoint(b.centerCoordinate)
    let center = MKMapPoint(x: pa.x + (pb.x - pa.x) * t, y: pa.y + (pb.y - pa.y) * t).coordinate
    // Zoom geometrically so the change feels even.
    let distance = exp(log(max(a.centerCoordinateDistance, 1)) * (1 - t) + log(max(b.centerCoordinateDistance, 1)) * t)
    return MKMapCamera(lookingAtCenter: center, fromDistance: distance,
                       pitch: a.pitch + (b.pitch - a.pitch) * t,
                       heading: smoothAngle(a.heading, b.heading, t))
}
