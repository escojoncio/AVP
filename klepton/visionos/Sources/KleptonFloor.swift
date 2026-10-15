// Build 58 (user report): Alyx's height was wrong whether the player sat or stood, and the manual "Altura del
// jugador" could not fix it. The game's floor was the immersive space's origin, and on device that origin is not
// reliably on the real floor (logs: head Y 0.94 m seated and about the same standing). A fixed offset cannot follow a
// floor that is wrong by a different amount each session.
//
// The visionOS answer is to MEASURE the floor: ARKit's PlaneDetectionProvider classifies horizontal planes, and a
// `.floor` PlaneAnchor's Y is in the same origin space as WorldTrackingProvider's DeviceAnchor. So
// "head above the real floor" = deviceY - floorY, continuously, seated or standing. The floor Y goes to the OpenVR
// shim (klvr_plat_set_floor_y, an atomic), which subtracts it from the head AND both hands, so the game's standing
// universe has y = 0 on the real floor; the manual height becomes a fine trim on top.
//
// The provider joins the compositor's one ARKitSession (a second session is not needed, and the provider list is
// fixed at run(), which runARKit already re-runs for controller changes). It needs world sensing; refused or
// unsupported, nothing changes from B38 and the log says why.
//
// The floor is never applied as a jump: a new value is only taken when it moves more than 3 cm and stays there for
// two checks (~1 s), and then eased in over ~1 s on the render thread.

import ARKit
import Foundation
import QuartzCore
import simd

final class KleptonFloor {
    /// The in-app "Altura real (detecta el suelo)" (KLVR_REAL_FLOOR at launch, live from AVPSettings.applyLive).
    /// Off = the floor shift eases back to 0 (B38 behaviour); the provider, once running, is left running.
    nonisolated(unsafe) static var enabled: Bool = klEnvOn("KLVR_REAL_FLOOR", default: true)

    private enum State { case notTried, asking, included, refused }

    private let lock = NSLock()
    // Everything under `lock`: written by the session task and the anchor task, read on the render thread.
    private var state = State.notTried
    private var provider: PlaneDetectionProvider?
    private var consumerStarted = false
    private var planes: [UUID: (y: Float, area: Float)] = [:]

    // Render thread only (tick).
    private var target: Float?            // the floor Y accepted (deadband + stability)
    private var pending: Float?           // a candidate > 3 cm off the target, waiting one more check
    private var easeFrom: Float = 0, easeTo: Float = 0, easeStart: TimeInterval = 0, applied: Float = 0
    private var lastCheck: TimeInterval = 0, lastLog: TimeInterval = 0
    private var lastPlaneCount = 0
    private var loggedOff = false, loggedNoFloor = false

    private static let easeSeconds: TimeInterval = 1.0
    private static let deadband: Float = 0.03
    private static let checkEvery: TimeInterval = 0.5

    // MARK: Session side (runARKit's task)

    /// The plane provider to add to this run, or nil. Never asks for anything (sync, no await): only a provider whose
    /// world sensing is already ALLOWED. Once included it is returned for every later run, whoever asks for the run.
    func providerForRun() -> PlaneDetectionProvider? {
        lock.lock(); defer { lock.unlock() }
        return state == .included ? provider : nil
    }

    /// Build 58 (review): the permission is asked AFTER the head and hands run (KleptonCompositor.runARKit), on its own
    /// task. Claims the one ask (notTried -> asking) so a per-frame caller spawns it once.
    func claimAuthorization() -> Bool {
        guard Self.enabled else { return false }
        lock.lock(); defer { lock.unlock() }
        guard state == .notTried else { return false }
        state = .asking
        return true
    }

    /// After claimAuthorization: true = allowed and the provider is ready, so the caller runs the session again.
    /// Only sync helpers touch the lock; this function just awaits the dialog.
    func authorize(_ session: ARKitSession) async -> Bool {
        guard PlaneDetectionProvider.isSupported else {
            refuse("PlaneDetectionProvider not supported here")
            return false
        }
        let auth = await session.requestAuthorization(for: [.worldSensing])
        let status = auth[.worldSensing]
        guard status == .allowed else {
            refuse("world sensing \(status.map { "\($0)" } ?? "unknown")")
            return false
        }
        include(PlaneDetectionProvider(alignments: [.horizontal]))
        NSLog("[height] world sensing allowed: adding floor detection to the ARKit session")
        return true
    }

    private func include(_ p: PlaneDetectionProvider) {
        lock.lock(); defer { lock.unlock() }
        provider = p; state = .included
    }

    /// The session ran with `p` in it: start reading its anchors (once per provider).
    func didRun(with p: PlaneDetectionProvider?) {
        guard let p else { return }
        lock.lock()
        let start = !consumerStarted && provider === p
        if start { consumerStarted = true }
        lock.unlock()
        guard start else { return }
        NSLog("[height] floor detection running (ARKit horizontal planes, real floor \(Self.enabled ? "on" : "off"))")
        Task { await self.consume(p) }
    }

    /// The run that included the plane provider failed: drop it so the next run keeps the head working.
    func runFailed(with p: PlaneDetectionProvider?) {
        guard p != nil else { return }
        refuse("ARKitSession.run failed with plane detection in it")
    }

    private func refuse(_ why: String) {
        lock.lock(); state = .refused; provider = nil; planes.removeAll(); lock.unlock()   // sync: never across an await
        NSLog("[height] real floor unavailable (\(why)): the game keeps the immersive-space origin as its floor "
              + "(B38 behaviour, manual height only)")
    }

    private func consume(_ p: PlaneDetectionProvider) async {
        for await update in p.anchorUpdates {
            note(update.anchor, removed: update.event == .removed)
        }
        NSLog("[height] plane updates ended: the last floor stays applied until the next ARKit run restarts them")
        consumerEnded()
    }

    // A re-run of the session (a controller change) may end the stream: let the next didRun read it again.
    private func consumerEnded() { lock.lock(); consumerStarted = false; lock.unlock() }

    // Synchronous, so the lock never spans a suspension point (same reason as KleptonControllers.store).
    private func note(_ a: PlaneAnchor, removed: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard !removed, a.classification == .floor else { planes[a.id] = nil; return }
        let e = a.geometry.extent
        planes[a.id] = (a.originFromAnchorTransform.columns.3.y, e.width * e.height)
    }

    // MARK: Render thread

    /// The floor among the detected `.floor` planes: plausible for this head (0.25-2.4 m below it, at least 0.25 m^2),
    /// then the LOWEST of the big ones (>= half the largest), so a small raised patch never wins over the room's floor.
    private func candidate(headY: Float) -> (y: Float, n: Int)? {
        lock.lock()
        let all = Array(planes.values)
        lock.unlock()
        let ok = all.filter { $0.y.isFinite && headY - $0.y >= 0.25 && headY - $0.y <= 2.4 && $0.area >= 0.25 }
        guard let biggest = ok.map({ $0.area }).max() else { return nil }
        guard let y = ok.filter({ $0.area >= 0.5 * biggest }).map({ $0.y }).min() else { return nil }
        return (y, ok.count)
    }

    /// Once per composited frame, with the raw ARKit head Y (nil when the tracker did not answer). Pushes the eased
    /// floor Y to the C side every call; logs on change and once a minute.
    func tick(headY: Float?) {
        let now = CACurrentMediaTime()
        lock.lock(); let included = state == .included; let refused = state == .refused; lock.unlock()
        let on = Self.enabled && included

        if on, let headY, now - lastCheck >= Self.checkEvery {
            lastCheck = now
            if let c = candidate(headY: headY) {
                lastPlaneCount = c.n
                loggedNoFloor = false
                if let t = target {
                    if abs(c.y - t) > Self.deadband {
                        // Stable for two checks (~1 s) before it is taken: a plane being refined, or one seen through
                        // a doorway for a moment, does not move the player.
                        if let p = pending, abs(p - c.y) <= Self.deadband {
                            target = c.y; pending = nil
                            log(headY: headY, why: "floor moved")
                        } else {
                            pending = c.y
                        }
                    } else {
                        pending = nil
                    }
                } else {
                    target = c.y
                    log(headY: headY, why: "floor found")
                }
            } else {
                lastPlaneCount = 0
                if target == nil, !loggedNoFloor, now - lastLog >= 10 {
                    loggedNoFloor = true
                    lastLog = now
                    NSLog("[height] no floor plane yet (head Y=\(Self.f3(headY))): applied shift "
                          + "\(Self.f3(klvr_plat_height_shift())) m (manual only)")
                }
            }
        }

        // What the C side should hold: the accepted floor while on, 0 (B38) otherwise.
        let goal: Float = on ? (target ?? 0) : 0
        if abs(goal - easeTo) > 0.0005 {
            easeFrom = applied; easeTo = goal; easeStart = now
            if !on, !loggedOff, target != nil {
                loggedOff = true
                NSLog("[height] real floor switched off: easing the floor shift back to the B38 origin")
            }
        }
        if on { loggedOff = false }
        let s = Float(min(1, max(0, (now - easeStart) / Self.easeSeconds)))
        applied = easeFrom + (easeTo - easeFrom) * (s * s * (3 - 2 * s))   // smoothstep: no jerk at either end
        klvr_plat_set_floor_y(applied)

        if now - lastLog >= 60 {
            if on, target != nil {
                log(headY: headY, why: "every minute")
            } else {
                lastLog = now
                let why = Self.enabled ? (refused ? "unavailable" : "waiting for a floor plane") : "off (setting)"
                NSLog("[height] real floor \(why): applied shift \(Self.f3(klvr_plat_height_shift())) m"
                      + (headY.map { ", head Y=\(Self.f3($0))" } ?? ""))
            }
        }
    }

    private func log(headY: Float?, why: String) {
        lastLog = CACurrentMediaTime()
        guard let t = target else { return }
        let above = headY.map { $0 - t }
        let posture = above.map { $0 < 1.35 ? "seated" : "standing" } ?? "unknown"
        // The applied shift is what the game gets NOW (it may still be easing); the target is manual - floor.
        let shift = klvr_plat_height_shift()
        NSLog("[height] floor at Y=\(Self.f3(t)) (\(lastPlaneCount) planes), head "
              + "\(above.map { String(format: "%.2f", $0) } ?? "?") m above floor (\(posture) guess), applied shift "
              + "\(Self.f3(shift)) m (target \(Self.f3(shift + applied - t)), \(why))")
    }

    private static func f3(_ v: Float) -> String { String(format: "%.3f", v) }
}
