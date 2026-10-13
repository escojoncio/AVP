// AVP: the boot glue between the launcher (app/) and Klepton for Half-Life: Alyx.
//
// The launcher prepares four folders (AVPLaunchPaths) and calls AlyxBoot.launch on the main actor. From there:
// configure (kl_app_configure_alyx: the env file, the convars, video2.txt and the fidelity table installed into the
// game folder, the library search pointed at the signed dylibs), boot (kl_app_boot: the guest's libraries load,
// nothing runs yet), the audio session, and the immersive space — whose compositor starts the guest
// (kl_app_lifecycle_begin -> kl_alyx_run on its own thread, paced by the OpenVR shim's WaitGetPoses).
// Everything diagnostic goes to <data>/logs/klepton-boot.log.
//
// Ideas taken from Glovebox's KleptonAlyxLauncher.swift (MIT): the pipeline replay's progress for the loading
// screen (kl_foz_progress), and "Preparing graphics" before Play (kl_foz_prewarm on a device made from the game's
// recorded settings) so the first frame is not a three-minute black space.

import Foundation
import SwiftUI

public struct AVPLaunchPaths {
    /// The folder that contains bin/, hlvr/, core/ (the depot's game/), with the real ELF files.
    public let gameDir: URL
    /// Flat folder of signed <stem>.dylib translations: the only library search path.
    public let dylibDir: URL
    /// alyx-env.txt (KEY=VALUE lines, # comments), alyx-convars.lua, video2.txt,
    /// vr_fidelity_levels_override.csv (and optionally device-info.json for the prewarm).
    public let configDir: URL
    /// Writable: klfz/ (pipelines, device info, perf), logs/ (klepton-boot.log, klepton-crash.log).
    public let dataDir: URL

    public init(gameDir: URL, dylibDir: URL, configDir: URL, dataDir: URL) {
        self.gameDir = gameDir
        self.dylibDir = dylibDir
        self.configDir = configDir
        self.dataDir = dataDir
    }
}

public enum AlyxBoot {
    /// Captured from the launcher window's environment (AlyxBootHost, KleptonApp.swift), so launch() can open the
    /// immersive space and close the window without a view of its own.
    @MainActor static var openSpace: OpenImmersiveSpaceAction?
    @MainActor static var openWindow: OpenWindowAction?
    @MainActor static var dismissWindow: DismissWindowAction?

    /// What the last launch reported (kl_app_status), for the launcher's error view.
    @MainActor public private(set) static var status = ""
    /// Set when launch() failed before the immersive space opened.
    @MainActor public private(set) static var failed = false
    @MainActor private static var launched = false

    /// Opens the immersive space and starts the guest. Call once, on the main actor, from the launcher.
    /// Configure and boot run off the main thread (the guest's library loading blocks for seconds, and a blocked
    /// main thread is a watchdog kill); the space opens once boot has succeeded.
    @MainActor public static func launch(_ p: AVPLaunchPaths) {
        guard !launched else { NSLog("[alyx] launch: already launched in this process"); return }
        launched = true
        failed = false
        Lifecycle.gameStarted = true
        Lifecycle.bootFailed = false
        Lifecycle.firstPicture = false
        let resources = Bundle.main.bundlePath
        let game = p.gameDir.path, dylibs = p.dylibDir.path, config = p.configDir.path, data = p.dataDir.path
        NSLog("[alyx] launch: game=\(game) dylibs=\(dylibs) config=\(config) data=\(data)")
        Thread.detachNewThread {
            var rc = kl_app_configure_alyx(resources, game, dylibs, config, data)
            if rc == 0 { rc = kl_app_boot() }
            let text = String(cString: kl_app_status())
            if rc == 0 { KleptonAudio.start() }   // after boot (the log is open), before the guest opens audio
            DispatchQueue.main.async {
                status = text
                guard rc == 0 else {
                    NSLog("[alyx] launch failed: \(text)")
                    failed = true
                    Lifecycle.bootFailed = true
                    return
                }
                openImmersive()
            }
        }
    }

    /// Pipelines replayed so far of the total known (the total grows as each database opens): kl_foz_progress.
    /// (0, 0) when no replay runs.
    public static func pipelineProgress() -> (done: Int, total: Int) {
        var done: UInt32 = 0, total: UInt32 = 0, elapsed: Double = 0
        let state = kl_foz_progress(&done, &total, &elapsed)
        if state == 0 { return (0, 0) }
        return (Int(done), Int(total))
    }

    /// Warms the Metal pipeline cache before Play, with no game running: a device made as the game makes its own
    /// (<data>/klfz/device-info.json, written at each game launch; else <config>/device-info.json) replays every
    /// pipeline database in <data>/klfz. Blocks for minutes on a first run: call it off the main thread, and poll
    /// pipelineProgress(). Configures the runtime (once per process), so launch() later reuses that configuration.
    @discardableResult public static func prewarm(_ p: AVPLaunchPaths) -> Int32 {
        let t0 = Date()
        let rc = kl_app_prewarm_alyx(Bundle.main.bundlePath, p.gameDir.path, p.dylibDir.path,
                                     p.configDir.path, p.dataDir.path)
        NSLog("[alyx] prewarm: %@ in %.1f s", rc == 0 ? "done" : "not possible (\(rc)); the game's own replay is the fallback",
              Date().timeIntervalSince(t0))
        return rc
    }

    @MainActor private static func openImmersive() {
        guard let open = openSpace else {
            NSLog("[alyx] no OpenImmersiveSpaceAction captured (AlyxBootHost missing from the launcher window)")
            failed = true
            Lifecycle.bootFailed = true
            status = "internal: the immersive space cannot be opened from here"
            return
        }
        // Alyx draws its own hands; the system's passthrough hands sat on top of them (KL_ALYX_LIMBS=1 keeps them).
        if ProcessInfo.processInfo.environment["KL_ALYX_LIMBS"] != "1" {
            KleptonChroma.shared.settings.handMatting = false
        }
        KleptonChroma.shared.immersionFull = !Immersive.mixed && !Immersive.prepPassthrough
        KleptonChroma.shared.startPassthroughWatch()
        Task { @MainActor in
            let r = await open(id: Immersive.id)
            NSLog("[cp] openImmersiveSpace -> \(r)")
            guard case .opened = r else {
                failed = true
                Lifecycle.bootFailed = true
                status = "the immersive space did not open (\(r))"
                return
            }
            Lifecycle.immersiveOpen = true
            Lifecycle.reopenLauncher = openWindow
            if Immersive.prepPassthrough {
                // .mixed with transparent frames until the game's first picture, then fully immersive.
                while !Lifecycle.firstPicture && !Lifecycle.bootFailed {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                if Lifecycle.firstPicture {
                    NSLog("[cp] first picture — the space turns fully immersive")
                    KleptonChroma.shared.immersionFull = true
                }
            } else {
                while !Lifecycle.firstPicture && !Lifecycle.bootFailed {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }
            // The launcher's loading view stays until the first frame, so the space is never just black.
            if Lifecycle.firstPicture, let dismiss = dismissWindow {
                NSLog("[app] first frame — dismissing the launcher window")
                dismiss(id: AVPMainWindow.id)
            }
        }
    }
}

/// Captures the launcher window's SwiftUI actions for AlyxBoot (applied in KleptonApp's WindowGroup).
struct AlyxBootHost: ViewModifier {
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    func body(content: Content) -> some View {
        content.onAppear {
            AlyxBoot.openSpace = openImmersiveSpace
            AlyxBoot.openWindow = openWindow
            AlyxBoot.dismissWindow = dismissWindow
        }
    }
}
