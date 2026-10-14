// AVP: from the launcher to the game. Chooses the Vulkan driver, writes the config the app rules
// with, pushes VPKEngine's settings and hands AlyxBoot (klepton/visionos/Sources/AlyxBoot.swift)
// the four folders.

import Foundation

enum AVPLaunch {
    /// VPVulkan inside the app, if this build carries it.
    static var vpvulkanPath: String? {
        let frameworks = Bundle.main.privateFrameworksPath ?? (Bundle.main.bundlePath + "/Frameworks")
        let path = frameworks + "/VPVulkan.framework/VPVulkan"
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// The driver chosen by selectDriver() (KL_MVK_DYLIB), nil for Klepton's default (MoltenVK).
    nonisolated(unsafe) private(set) static var driverPath: String?

    /// VPKEngine is opened here first with RTLD_GLOBAL, so the settings reach it (vpvk_config_set_*) before the
    /// game creates its device; Klepton's own dlopen of the same path then returns this handle. MoltenVK only runs
    /// when this build carries no VPVulkan (the setting that chose it is gone since build 32: it was a diagnostic
    /// nobody plays with).
    static func selectDriver() {
        driverPath = nil
        unsetenv("KL_MVK_DYLIB")
        guard let path = vpvulkanPath else {
            AVPLog.log("Gráficos: esta build no trae VPVulkan; se usa MoltenVK")
            return
        }
        if dlopen(path, RTLD_NOW | RTLD_GLOBAL) != nil {
            driverPath = path
            setenv("KL_MVK_DYLIB", path, 1)
            AVPLog.log("Gráficos: VPKEngine (VPVulkan) \(path)")
        } else {
            let reason = dlerror().map { String(cString: $0) } ?? "?"
            AVPLog.log("Gráficos: VPVulkan no carga (\(reason)); se usa MoltenVK")
        }
    }

    enum Problem: Error, LocalizedError {
        case notReady(String)
        var errorDescription: String? {
            switch self { case .notReady(let m): return m }
        }
    }

    /// Everything the game needs, prepared and written. Call off the main thread.
    static func paths(prepared: AVPPrepare.Prepared) throws -> AVPLaunchPaths {
        guard let game = AVPFolder.shared.game else {
            throw Problem.notReady(AVPL("No hay carpeta AVP.", "There is no AVP folder."))
        }
        selectDriver()
        let settings = AVPSettings.shared
        let env = try settings.writeConfig(.init(gameDir: game, configDir: AVPFolder.config, dataDir: AVPFolder.data,
                                                 pipelines: prepared.pipelines))
        // Also in this process's environment, for anything that reads it before AlyxBoot parses the file.
        for (k, v) in env { setenv(k, v, 1) }
        setenv("KL_AUTOBOOT", "1", 1)
        setenv("KL_IMMERSIVE", "1", 1)
        settings.applyToVPKEngine()
        return AVPLaunchPaths(gameDir: game, dylibDir: prepared.signed, configDir: AVPFolder.config, dataDir: AVPFolder.data)
    }

    /// Set by the launcher just before the game boots.
    nonisolated(unsafe) static var chosen: AVPLaunchPaths?

    /// Called by BootView's boot thread (KleptonApp.swift) where VisionQuestPro called VQLaunch.configure().
    static func configure() -> Int32 {
        guard let paths = chosen else {
            AVPLog.log("Arranque: no hay rutas preparadas")
            return 1
        }
        AVPLog.log("Arranque: game=\(paths.gameDir.path) dylibs=\(paths.dylibDir.path) config=\(paths.configDir.path) data=\(paths.dataDir.path)")
        // The loading panel in the immersive space (until the game's first picture): the cached Steam art. With
        // none cached the panel still shows, with the title as text over a plain background.
        let art = AVPArtCache.loadingPanelFiles()
        KleptonCompositor.loadingArt = art
        KleptonCompositor.loadingEnabled = true
        AVPLog.log("Arranque: pantalla de carga con \(art.filter { !$0.isEmpty }.count) de 2 imágenes de Steam en caché")
        AVPLog.mirrorToFolder()
        AVPLog.startPeriodicMirror()
        try? FileManager.default.createDirectory(at: AVPLog.directory, withIntermediateDirectories: true)
        setenv("KL_ALYX_LOG_DIR", AVPLog.directory.path, 1)
        // Configure only: BootView (KleptonApp.swift) then runs kl_app_boot and opens the immersive space.
        return kl_app_configure_alyx(Bundle.main.bundlePath, paths.gameDir.path, paths.dylibDir.path,
                                     paths.configDir.path, paths.dataDir.path)
    }
}
