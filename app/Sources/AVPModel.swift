// AVP: the launcher's state. Steam sign-in (password + Steam Guard), ownership, download
// (pause/resume, background), preparation steps, Steam Cloud and Play. Main-actor; the slow work
// runs in tasks and threads and reports back here.

import ARKit
import Foundation
import GameController
import SwiftUI
import UIKit

@MainActor
final class AVPModel: ObservableObject {
    static let shared = AVPModel()

    enum Phase: Equatable { case needFolder, signIn, checkingOwnership, notOwned, library }
    enum SignInStep: Equatable { case idle, working, approveInApp(canEnterCode: Bool), enterCode(email: String?) }
    enum Install: Equatable {
        case unknown, planning, notInstalled
        case downloading(DownloadProgress), paused(DownloadProgress)
        case installed(updateAvailable: Bool)
        case failed(String)
    }
    enum Saves: Equatable { case idle, syncing(String), synced, failed(String), off }
    enum ControllerAccess: Equatable { case notAsked, allowed, denied }

    @Published var phase: Phase = .needFolder
    @Published var signInStep: SignInStep = .idle
    @Published var signInError: String?
    @Published var accountName = ""
    @Published var install: Install = .unknown
    @Published var downloadBytes: UInt64 = 0
    @Published var buildID: UInt64 = 0
    @Published var spaceProblem: String?
    @Published var saves: Saves = .idle
    @Published var message: String?
    @Published var certificate: String? = AVPSigner.current
    @Published var folderPath: String?

    // Preparation
    @Published var preparing = false
    @Published var prepStep = 0
    @Published var prepFraction: Double = 0
    @Published var prepText = ""
    @Published var prepared: Bool = UserDefaults.standard.bool(forKey: "avp.prepared")

    // Play
    @Published var controllersConnected = 0
    @Published var senseControllers: [SenseController] = []
    @Published var controllerAccess: ControllerAccess = .notAsked
    @Published var launching = false
    @Published var running = false        // BootView is showing
    @Published var ended = false          // the game's immersive space has closed
    @Published var paused = false         // the game is held (pause menu / space taken by the system); "Volver al juego"

    private var launcher: SteamLauncher?
    private var plan: SteamLauncher.InstallPlan?
    private var authSession: SteamAuthSession?
    private var signInTask: Task<Void, Never>?
    private var installTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private let arSession = ARKitSession()
    private var resumeWhenActive = false

    private init() {
        AVPLog.start()
        AVPLog.log("Inicio: modelo M5 \(AVPSettings.isM5)")
        watchControllers()
        start()
    }

    // MARK: Folder

    func start() {
        folderPath = AVPFolder.shared.url?.path
        guard let game = AVPFolder.shared.game else { phase = .needFolder; return }
        if launcher == nil || launcher?.installRoot != game {
            let l = SteamLauncher(profile: .halfLifeAlyx, installRoot: game)
            l.log = { AVPLog.log("Steam: \($0)") }
            launcher = l
            AVPBackground.fetcher(for: game).activate()
        }
        if let creds = AVPKeychain.load() {
            accountName = creds.accountName
            Task { await finishSignIn(creds) }
        } else {
            phase = .signIn
        }
    }

    func choose(_ url: URL) {
        if let problem = AVPFolder.shared.choose(url) { message = problem } else { message = nil }
        start()
    }

    // MARK: Sign-in

    func signIn(account: String, password: String) {
        guard let launcher else { return }
        if SteamAuth.passwordTooLong(password) { signInError = SteamError.passwordTooLong.friendly; return }
        signInError = nil
        signInStep = .working
        signInTask?.cancel()
        AVPLog.log("Steam: inicio de sesión con contraseña para \(account)")
        signInTask = Task {
            do {
                let session = try await launcher.beginPasswordSignIn(account: account, password: password,
                                                                     guardData: AVPKeychain.guardData(for: account))
                authSession = session
                accountName = account
                switch session.prompt {
                case .approveInApp(let canEnterCode): signInStep = .approveInApp(canEnterCode: canEnterCode)
                case .deviceCode: signInStep = .enterCode(email: nil)
                case .emailCode(let hint): signInStep = .enterCode(email: hint)
                case .qr: break
                }
                AVPLog.log("Steam: Steam Guard pide \(session.prompt)")
                let creds = try await session.waitForApproval()
                await finishSignIn(creds)
            } catch {
                if Task.isCancelled { return }
                AVPLog.log("Steam: inicio de sesión falló: \(error)")
                signInStep = .idle
                signInError = avpFriendly(error)
            }
        }
    }

    func submitCode(_ code: String) {
        guard let s = authSession else { return }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        Task {
            do { try await s.submit(code: trimmed) } catch { signInError = avpFriendly(error) }
        }
    }

    func useCodeInstead() { signInStep = .enterCode(email: nil) }

    func cancelSignIn() {
        signInTask?.cancel()
        authSession = nil
        signInStep = .idle
    }

    private func finishSignIn(_ creds: SteamCredentials) async {
        guard let launcher else { return }
        var creds = creds
        if creds.accountName.isEmpty { creds.accountName = accountName }
        AVPKeychain.save(creds)
        accountName = creds.accountName
        signInStep = .idle
        phase = .checkingOwnership
        do {
            try await launcher.logOn(creds)
            AVPLog.log("Steam: sesión iniciada como \(creds.accountName)")
            let own = try await launcher.checkOwnership()
            AVPLog.log("Steam: propiedad de Half-Life: Alyx: \(own.owned) (paquete \(own.packageID.map(String.init) ?? "-"), depósitos \(own.depotIDs.sorted()))")
            guard own.owned else { phase = .notOwned; return }
            phase = .library
            if AVPSettings.shared.cloudSync { syncSaves(reason: "inicio") } else { saves = .off }
            await refreshInstall()
        } catch SteamError.result(let r, _) where r == .invalidPassword || r == .accessDenied || r == .expired {
            AVPLog.log("Steam: el token guardado ya no vale (\(r))")
            AVPKeychain.clear()
            phase = .signIn
            signInError = AVPL("Vuelve a iniciar sesión.", "Sign in again.")
        } catch {
            AVPLog.log("Steam: fallo tras iniciar sesión: \(error)")
            phase = .signIn
            signInError = avpFriendly(error)
        }
    }

    func signOut() {
        installTask?.cancel()
        if let game = AVPFolder.shared.game { Task { await AVPBackground.fetcher(for: game).stop() } }
        if let launcher { Task { await launcher.signOut() } }
        AVPKeychain.clear()
        accountName = ""
        install = .unknown
        phase = .signIn
        AVPLog.log("Steam: sesión cerrada")
    }

    // MARK: Download

    func refreshInstall() async {
        guard let launcher, phase == .library else { return }
        install = .planning
        do {
            let p = try await launcher.plan()  // depot keys + manifest codes: only owners get them
            plan = p
            buildID = p.buildID
            let remaining = await Task.detached { launcher.remainingChunks(p).reduce(UInt64(0)) { $0 + UInt64($1.bytes) } }.value
            downloadBytes = p.totalBytes
            spaceProblem = AVPFolder.shared.spaceProblem(downloadBytes: remaining)
            AVPLog.log("Descarga: plan build \(p.buildID), \(AVPLog.bytes(p.totalBytes)) en total, faltan ~\(AVPLog.bytes(remaining)), libre \(AVPFolder.shared.freeSpace.map(AVPLog.bytes) ?? "?")")
            if launcher.installed == nil {
                install = .notInstalled
            } else {
                install = .installed(updateAvailable: launcher.needsUpdate(p))
            }
        } catch {
            AVPLog.log("Descarga: no se pudo planificar: \(error)")
            install = .failed(avpFriendly(error))
        }
    }

    func startInstall() {
        guard let plan, let launcher, let game = AVPFolder.shared.game else { return }
        // The signing certificate comes first: without it nothing downloaded could ever run.
        guard certificate != nil else {
            message = AVPL("Importa primero tu certificado (.p12).", "Import your certificate (.p12) first."); return
        }
        if let problem = spaceProblem { message = problem; return }
        installTask?.cancel()
        resumeWhenActive = false
        var first = DownloadProgress()
        first.totalBytes = plan.totalBytes
        install = .downloading(first)
        AVPLog.log("Descarga: empieza/continúa")
        UIApplication.shared.isIdleTimerDisabled = true
        installTask = Task {
            do {
                let report: @Sendable (DownloadProgress) -> Void = { p in
                    Task { @MainActor in
                        guard case .downloading = AVPModel.shared.install else { return }
                        AVPModel.shared.install = .downloading(p)
                    }
                }
                let background = AVPBackground.fetcher(for: game)
                let remaining = await Task.detached { launcher.remainingChunks(plan) }.value
                await background.plan(remaining, servers: CDNClient(servers: plan.servers).baseURLs, firstBatchShare: 0.5)
                let pending = await background.pendingNames()
                try await launcher.install(plan, skipping: pending, progress: report)
                if !pending.isEmpty {
                    await background.stop()
                    try await launcher.install(plan, progress: report)
                }
                await background.stop()
                AVPLog.log("Descarga: completa")
                install = .installed(updateAvailable: false)
                prepared = false
                UserDefaults.standard.set(false, forKey: "avp.prepared")
            } catch is CancellationError {
            } catch {
                if Task.isCancelled { return }
                if case .paused = install { return }
                AVPLog.log("Descarga: falló: \(error)")
                install = .failed(avpFriendly(error))
            }
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    func pauseInstall() {
        if case .downloading(let p) = install { install = .paused(p) }
        installTask?.cancel()
        resumeWhenActive = false
        if let game = AVPFolder.shared.game { Task { await AVPBackground.fetcher(for: game).stop() } }
        UIApplication.shared.isIdleTimerDisabled = false
        AVPLog.log("Descarga: en pausa")
    }

    private var mirroredAtOpen = false
    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            // The previous session's logs (its boot log is still in Documents until the next Play) reach the
            // AVP folder as soon as the app is open again, even if that session was killed in the immersive space.
            if !mirroredAtOpen { mirroredAtOpen = true; DispatchQueue.global(qos: .utility).async { AVPLog.mirrorToFolder() } }
            if resumeWhenActive { startInstall() }
            refreshControllerAccess()
        case .background:
            handDownloadToSystem()
            AVPLog.mirrorToFolder()
        default: break
        }
    }

    /// Leaving the app mid-download: the system's background session takes the rest.
    private func handDownloadToSystem() {
        guard case .downloading = install, let plan, let launcher, let game = AVPFolder.shared.game else { return }
        resumeWhenActive = true
        let running = installTask
        running?.cancel()
        final class Assertion: @unchecked Sendable { var id = UIBackgroundTaskIdentifier.invalid }
        let assertion = Assertion()
        assertion.id = UIApplication.shared.beginBackgroundTask(withName: "AVP download hand-off") {
            MainActor.assumeIsolated { UIApplication.shared.endBackgroundTask(assertion.id) }
        }
        Task {
            await running?.value
            let remaining = await Task.detached { launcher.remainingChunks(plan) }.value
            await AVPBackground.fetcher(for: game).plan(remaining, servers: CDNClient(servers: plan.servers).baseURLs)
            AVPLog.log("Descarga: \(remaining.count) trozos pasados a la descarga en segundo plano del sistema")
            UIApplication.shared.endBackgroundTask(assertion.id)
        }
    }

    // MARK: Steam Cloud

    /// Download-then-upload, backups before replacing, never propagates deletions (CloudSync).
    func syncSaves(reason: String) {
        guard saveTask == nil, let launcher, AVPSettings.shared.cloudSync else { return }
        saves = .syncing(AVPL("Comprobando", "Checking"))
        saveTask = Task {
            let t0 = Date()
            do {
                let r = try await launcher.syncSaves(uploads: true) { p in
                    let text: String
                    switch p.stage {
                    case .checking: text = AVPL("Comprobando", "Checking")
                    case .downloading: text = AVPL("Bajando \(p.done)/\(p.total)", "Downloading \(p.done)/\(p.total)")
                    case .uploading: text = AVPL("Subiendo \(p.done)/\(p.total)", "Uploading \(p.done)/\(p.total)")
                    }
                    await MainActor.run { AVPModel.shared.saves = .syncing(text) }
                }
                AVPLog.log("Nube (\(reason)): \(Int(Date().timeIntervalSince(t0))) s, bajadas \(r.downloaded.count), subidas \(r.uploaded.count), "
                           + "sin cambios \(r.unchanged), copias \(r.backedUp.count), no subidas \(r.wouldUpload.count)")
                saves = .synced
            } catch {
                AVPLog.log("Nube (\(reason)): falló: \(error)")
                saves = .failed(avpFriendly(error))
            }
            saveTask = nil
        }
    }

    // MARK: Certificate

    func refreshCertificate() { certificate = AVPSigner.current }

    // MARK: Preparation

    func prepare(thenPlay: Bool) {
        guard !preparing else { return }
        guard AVPSigner.current != nil else { message = AVPSigner.Problem.missing.errorDescription; return }
        preparing = true
        prepStep = 0
        prepFraction = 0
        prepText = AVPL("Empezando…", "Starting…")
        message = nil
        UIApplication.shared.isIdleTimerDisabled = true
        Thread.detachNewThread {
            let report: AVPPrepare.Progress = { step, fraction, text in
                Task { @MainActor in
                    let m = AVPModel.shared
                    m.prepStep = step; m.prepFraction = fraction; m.prepText = text
                }
            }
            do {
                let p = try AVPPrepare.prepare(progress: report)
                let paths = try AVPLaunch.paths(prepared: p)
                AVPPrepare.prewarm(paths, progress: report)
                Task { @MainActor in
                    let m = AVPModel.shared
                    m.preparing = false
                    m.prepared = true
                    UserDefaults.standard.set(true, forKey: "avp.prepared")
                    UIApplication.shared.isIdleTimerDisabled = false
                    AVPLaunch.chosen = paths
                    if thenPlay { m.boot() }
                }
            } catch {
                AVPLog.log("Preparar: falló: \(error.localizedDescription)")
                let text = error.localizedDescription
                Task { @MainActor in
                    let m = AVPModel.shared
                    m.preparing = false
                    m.message = text
                    UIApplication.shared.isIdleTimerDisabled = false
                }
            }
        }
    }

    // MARK: Controllers (PS VR2 Sense)

    var controllerIssue: String? {
        if controllerAccess == .denied {
            return AVPL("El seguimiento de mandos está desactivado: actívalo en Ajustes.", "Controller tracking is off: turn it on in Settings.")
        }
        if controllersConnected < 2 {
            return controllersConnected == 1
                ? AVPL("Enciende el otro mando PS VR2 Sense (botón PS).", "Turn on the other PS VR2 Sense controller (PS button).")
                : AVPL("Enciende los dos mandos PS VR2 Sense (botón PS). ¿Primera vez? Emparéjalos en Ajustes › Bluetooth.",
                       "Turn on both PS VR2 Sense controllers (PS button). First time? Pair them in Settings › Bluetooth.")
        }
        return nil
    }

    private func watchControllers() {
        countControllers()
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            _ = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { AVPModel.shared.countControllers() }
            }
        }
        refreshControllerAccess()
    }

    private func countControllers() {
        controllersConnected = GCController.controllers().filter { $0.productCategory == GCProductCategorySpatialController }.count
        AVPLog.log("Mandos Sense conectados: \(controllersConnected)")
        refreshBatteries()
    }

    // MARK: Controller batteries

    struct SenseController: Identifiable, Equatable {
        enum Hand: Equatable { case left, right, unknown(Int) }
        let id: ObjectIdentifier
        let hand: Hand
        let level: Float?           // 0...1, nil when the controller reports no battery
        let state: GCDeviceBattery.State?
    }

    private var batteryPoll: Timer?
    private var loggedBattery: [String: String] = [:]

    /// Polls every 20 s while the launcher is visible (connect/disconnect also refresh).
    func setBatteryPolling(_ on: Bool) {
        batteryPoll?.invalidate()
        batteryPoll = nil
        guard on else { return }
        refreshBatteries()
        batteryPoll = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in
            MainActor.assumeIsolated { AVPModel.shared.refreshBatteries() }
        }
    }

    /// GCController has no handedness property; the Sense controllers name their side in vendorName,
    /// e.g. "… (L)" / "… (R)" or "Left"/"Right". Unnamed ones fall back to their connection order.
    private static func hand(of c: GCController, index: Int) -> SenseController.Hand {
        let name = [c.vendorName, c.productCategory].compactMap { $0 }.joined(separator: " ")
        let lower = name.lowercased()
        if name.contains("(L)") || lower.contains("left") || lower.contains("izquierd") { return .left }
        if name.contains("(R)") || lower.contains("right") || lower.contains("derech") { return .right }
        return .unknown(index + 1)
    }

    func refreshBatteries() {
        let pads = GCController.controllers().filter { $0.productCategory == GCProductCategorySpatialController }
        var list: [SenseController] = []
        for (i, c) in pads.enumerated() {
            let b = c.battery
            list.append(SenseController(id: ObjectIdentifier(c), hand: Self.hand(of: c, index: i),
                                        level: b?.batteryLevel, state: b?.batteryState))
            let key = "\(c.vendorName ?? "mando") #\(i + 1)"
            let text: String
            if let b {
                let st: String
                switch b.batteryState {
                case .charging: st = "cargando"
                case .full: st = "llena"
                case .discharging: st = "descargando"
                default: st = "desconocido"
                }
                text = "\(Int((b.batteryLevel * 100).rounded())) % \(st)"
            } else {
                text = "sin datos"
            }
            if loggedBattery[key] != text {
                loggedBattery[key] = text
                AVPLog.log("Batería \(key): \(text)")
            }
        }
        list.sort { Self.order($0.hand) < Self.order($1.hand) }
        if list != senseControllers { senseControllers = list }
    }

    private static func order(_ h: SenseController.Hand) -> Int {
        switch h {
        case .left: return 0
        case .right: return 1
        case .unknown(let n): return 1 + n
        }
    }

    func refreshControllerAccess() {
        Task {
            let status = await arSession.queryAuthorization(for: [.accessoryTracking])
            controllerAccess = Self.access(status[.accessoryTracking])
        }
    }

    private func allowControllerTracking() async -> Bool {
        let status = await arSession.requestAuthorization(for: [.accessoryTracking])
        controllerAccess = Self.access(status[.accessoryTracking])
        AVPLog.log("Permiso de seguimiento de accesorios: \(controllerAccess)")
        return controllerAccess != .denied
    }

    private static func access(_ s: ARKitSession.AuthorizationStatus?) -> ControllerAccess {
        switch s {
        case .allowed?: return .allowed
        case .denied?: return .denied
        default: return .notAsked
        }
    }

    // MARK: Play

    var canPlay: Bool {
        if case .installed = install, !preparing, !launching, controllerIssue == nil, certificate != nil { return true }
        return false
    }

    func play() {
        guard canPlay else { return }
        launching = true
        Task {
            defer { launching = false }
            guard await allowControllerTracking() else { message = controllerIssue; return }
            // Saves first: what Steam Cloud has must be on disk before the game reads it.
            if AVPSettings.shared.cloudSync {
                await saveTask?.value
                syncSaves(reason: "antes de jugar")
                await saveTask?.value
                if case .failed(let why) = saves {
                    AVPLog.log("Jugar: la nube falló (\(why)); se juega con las partidas locales")
                }
            }
            AVPLog.log("Jugar: preparar (lo ya hecho se salta) y arrancar")
            prepare(thenPlay: true)
        }
    }

    /// Hands over to Klepton's BootView, which boots the guest (AVPLaunch.configure) and opens the space.
    func boot() {
        guard AVPLaunch.chosen != nil else { return }
        running = true
    }
}
