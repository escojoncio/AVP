// AVP: the settings that rule over the game. All of them live in the app (UserDefaults, the
// Settings screen); none is ever read back from a text file. On EVERY launch they are written
// into the config folder (AlyxBoot's configDir) and pushed to VPKEngine, overriding whatever the
// game's own files, its Options menu or Steam Cloud left behind:
//
//   alyx-env.txt                      KEY=VALUE for Klepton / the OpenVR shim / VPKEngine
//   video2.txt                        the game's video settings (from video2-visionpro-demo.txt)
//   vr_fidelity_levels_override.csv   the fidelity table (one level, or a range for dynamic res)
//   alyx-convars.lua                  re-applies the forced convars at every spawn and every few seconds
//
// The keys follow Glovebox's packages/alyx/defaults/DEMO.txt and engine/gb/build.py defaults().

import Combine
import Foundation

final class AVPSettings: ObservableObject {
    static let shared = AVPSettings()

    // MARK: Values

    /// M2 and M5 use the user's foveation tested in PTVisionPro (sharp zone 60° across at full rate, centred 10° below
    /// each eye's forward axis): Klepton's KL_VRR_MAP=wide, with the periphery's quality (`periphery`) 10 % by
    /// default and up to 65 % for an M5 (`presetPeriphery`).
    enum Foveation: Int, CaseIterable { case off = 0, m2 = 1, m5 = 2, custom = 3 }
    enum Movement: Int, CaseIterable { case teleport = 0, continuousHead = 2, continuousHand = 3 }
    enum Engine: String, CaseIterable { case vpkengine, moltenvk }

    /// Vision Pro's native per-eye render size (what visionOS asks for at 100 %).
    static let nativeEye = (width: 3072, height: 2464)

    /// Render resolution as a percentage of the native eye size (50...130).
    @Published var renderPercent: Double { didSet { save() } }
    @Published var dynamicResolution: Bool { didSet { save() } }
    @Published var dynamicMin: Double { didSet { save() } }     // render target scale, 0.5...1.0
    @Published var dynamicMax: Double { didSet { save() } }     // 0.6...1.2
    @Published var texturePoolMB: Int { didSet { save() } }     // 1536...2816
    @Published var textureCap: Int { didSet { save() } }        // 1024 | 2048 | 4096
    @Published var foveation: Foveation { didSet { save() } }
    @Published var sharpZone: Double { didSet { save() } }      // 0.05...0.6 of the image width
    /// M2/M5: the sharp zone's width in degrees (30...70, PTVisionPro's 60 by default); the rest at `periphery`.
    @Published var wideDegrees: Double { didSet { save() } }
    @Published var periphery: Double { didSet { save() } }      // 0.1...1 shading rate at the edge
    @Published var transition: Double { didSet { save() } }     // 0.02...0.5
    @Published var vpktaa: Bool { didSet { save() } }
    @Published var vpktaaPercent: Double { didSet { save() } }  // 0...100
    @Published var vpktaaSharpness: Double { didSet { save() } } // 0...1
    @Published var anisotropy: Int { didSet { save() } }        // 0, 2, 4, 8, 16
    @Published var engine: Engine { didSet { save() } }
    @Published var systemLanguage: Bool { didSet { save() } }
    @Published var refreshHz: Int { didSet { save() } }         // 90 | 100
    @Published var halfRate: Bool { didSet { save() } }         // the game renders every 2nd display frame
    @Published var showFps: Bool { didSet { save() } }
    /// Build 26: the compositor composes only when the game has a new picture (KL_CP_SKIP_SAME); otherwise visionOS
    /// reprojects the last one. Log 18: re-compositing the same picture at 100 Hz took 7-19 ms of GPU per game frame.
    @Published var composeNewOnly: Bool { didSet { save() } }
    /// Ambient occlusion (r_ssao). On by default on every headset: fidelity is kept, performance comes from resolution.
    @Published var ssao: Bool { didSet { save() } }
    /// Build 27 (VPKEngine 0031) vertex amplification: forced OFF since build 29 (right eye broken, GPU faults); the
    /// stored value is kept but unused.
    @Published var vertexAmplification: Bool { didSet { save() } }
    /// Build 27 (VPKEngine 0031): command buffers wait only on the previous ones they really depend on (VP_CB_ORDER=2)
    /// instead of all of them (0029, VP_CB_ORDER=1). If vertex explosions come back, turn it off.
    @Published var trackedOrder: Bool { didSet { save() } }
    /// Build 27: the sharp zone composed as P.T.'s circle (KleptonCompositor.setRoundFovea) over the wide map.
    @Published var roundSharpZone: Bool { didSet { save() } }
    @Published var diagCaptures: Bool { didSet { save() } }
    /// Build 27: per-pass GPU timing windows (KL_GPU_PASSES, kl_gpu_time.m) with VPKEngine; off removes them.
    @Published var gpuPassProfiling: Bool { didSet { save() } }
    /// Command buffers VPKEngine lets the game queue ahead of the GPU (VP_FRAMES_IN_FLIGHT): 12 overlaps CPU and
    /// GPU (faster); 3 is the A/B test (build 23: no vertex explosions with 3, at half the frame rate). Build 24
    /// orders each command buffer after the whole previous one, so 12 is the default again (new key: a 3 chosen for
    /// the build-23 test does not stick).
    @Published var gpuQueueDepth: Int { didSet { save() } }     // 3 | 12
    @Published var movement: Movement { didSet { save() } }
    @Published var cloudSync: Bool { didSet { save() } }

    private var loading = true

    private init() {
        let d = UserDefaults.standard
        renderPercent = d.object(forKey: "avp.renderPercent") as? Double ?? 90
        dynamicResolution = d.object(forKey: "avp.dynRes") as? Bool ?? false
        dynamicMin = d.object(forKey: "avp.dynMin") as? Double ?? 0.7
        dynamicMax = d.object(forKey: "avp.dynMax") as? Double ?? 1.0
        texturePoolMB = d.object(forKey: "avp.texPool") as? Int ?? 2560
        textureCap = d.object(forKey: "avp.texCap") as? Int ?? 2048
        var fov = Foveation(rawValue: d.object(forKey: "avp.fov2") as? Int ?? 1) ?? .m2
        if fov == .m5 && !Self.isM5 { fov = .m2 }
        foveation = fov
        sharpZone = d.object(forKey: "avp.fovSharp") as? Double ?? 0.18
        wideDegrees = min(70, max(30, d.object(forKey: "avp.fovWideDeg") as? Double ?? 60))
        periphery = d.object(forKey: "avp.fovPeriphery2") as? Double ?? 0.10
        transition = d.object(forKey: "avp.fovTransition") as? Double ?? 0.32
        vpktaa = d.object(forKey: "avp.vpktaa") as? Bool ?? true
        vpktaaPercent = d.object(forKey: "avp.reconPercent") as? Double ?? 80
        vpktaaSharpness = d.object(forKey: "avp.reconSharp") as? Double ?? 1.0
        anisotropy = d.object(forKey: "avp.aniso") as? Int ?? 16
        engine = Engine(rawValue: d.string(forKey: "avp.engine") ?? "") ?? .vpkengine
        systemLanguage = d.object(forKey: "avp.sysLang") as? Bool ?? true
        refreshHz = d.object(forKey: "avp.refreshHz") as? Int ?? 90
        halfRate = d.object(forKey: "avp.halfRate") as? Bool ?? true
        showFps = d.object(forKey: "avp.showFps") as? Bool ?? false
        composeNewOnly = d.object(forKey: "avp.cpSkipSame") as? Bool ?? true
        ssao = d.object(forKey: "avp.ssao") as? Bool ?? true
        vertexAmplification = d.object(forKey: "avp.vkAmplify") as? Bool ?? true
        trackedOrder = d.object(forKey: "avp.cbOrder2b") as? Bool ?? false
        roundSharpZone = d.object(forKey: "avp.roundFov") as? Bool ?? true
        diagCaptures = d.object(forKey: "avp.diagCaptures") as? Bool ?? false
        gpuPassProfiling = d.object(forKey: "avp.gpuPasses") as? Bool ?? true
        gpuQueueDepth = (d.object(forKey: "avp.gpuQueueDepth24") as? Int).map { $0 == 3 ? 3 : 12 } ?? 12
        movement = Movement(rawValue: d.object(forKey: "avp.movement") as? Int ?? 3) ?? .continuousHand
        cloudSync = d.object(forKey: "avp.cloudSync") as? Bool ?? true
        loading = false
    }

    private func save() {
        guard !loading else { return }
        let d = UserDefaults.standard
        d.set(renderPercent, forKey: "avp.renderPercent")
        d.set(dynamicResolution, forKey: "avp.dynRes")
        d.set(dynamicMin, forKey: "avp.dynMin")
        d.set(dynamicMax, forKey: "avp.dynMax")
        d.set(texturePoolMB, forKey: "avp.texPool")
        d.set(textureCap, forKey: "avp.texCap")
        d.set(foveation.rawValue, forKey: "avp.fov2")
        d.set(sharpZone, forKey: "avp.fovSharp")
        d.set(wideDegrees, forKey: "avp.fovWideDeg")
        d.set(periphery, forKey: "avp.fovPeriphery2")
        d.set(transition, forKey: "avp.fovTransition")
        d.set(vpktaa, forKey: "avp.vpktaa")
        d.set(vpktaaPercent, forKey: "avp.reconPercent")
        d.set(vpktaaSharpness, forKey: "avp.reconSharp")
        d.set(anisotropy, forKey: "avp.aniso")
        d.set(engine.rawValue, forKey: "avp.engine")
        d.set(systemLanguage, forKey: "avp.sysLang")
        d.set(refreshHz, forKey: "avp.refreshHz")
        d.set(halfRate, forKey: "avp.halfRate")
        d.set(showFps, forKey: "avp.showFps")
        d.set(composeNewOnly, forKey: "avp.cpSkipSame")
        d.set(ssao, forKey: "avp.ssao")
        d.set(vertexAmplification, forKey: "avp.vkAmplify")
        d.set(trackedOrder, forKey: "avp.cbOrder2b")
        d.set(roundSharpZone, forKey: "avp.roundFov")
        d.set(diagCaptures, forKey: "avp.diagCaptures")
        d.set(gpuPassProfiling, forKey: "avp.gpuPasses")
        d.set(gpuQueueDepth, forKey: "avp.gpuQueueDepth24")
        d.set(movement.rawValue, forKey: "avp.movement")
        d.set(cloudSync, forKey: "avp.cloudSync")
    }

    func resetToDefaults() {
        for k in UserDefaults.standard.dictionaryRepresentation().keys where k.hasPrefix("avp.") && k != "avp.folderBookmark"
            && k != "avp.signatureVariant" {
            UserDefaults.standard.removeObject(forKey: k)
        }
        let fresh = AVPSettings.makeDefaults()
        renderPercent = fresh.renderPercent; dynamicResolution = fresh.dynamicResolution
        dynamicMin = fresh.dynamicMin; dynamicMax = fresh.dynamicMax
        texturePoolMB = fresh.texturePoolMB; textureCap = fresh.textureCap
        foveation = fresh.foveation; sharpZone = fresh.sharpZone; wideDegrees = fresh.wideDegrees; periphery = fresh.periphery; transition = fresh.transition
        vpktaa = fresh.vpktaa; vpktaaPercent = fresh.vpktaaPercent; vpktaaSharpness = fresh.vpktaaSharpness
        anisotropy = fresh.anisotropy; engine = fresh.engine
        systemLanguage = fresh.systemLanguage; refreshHz = fresh.refreshHz; halfRate = fresh.halfRate
        showFps = fresh.showFps; composeNewOnly = fresh.composeNewOnly; ssao = fresh.ssao
        vertexAmplification = fresh.vertexAmplification; trackedOrder = fresh.trackedOrder; roundSharpZone = fresh.roundSharpZone; diagCaptures = fresh.diagCaptures; gpuPassProfiling = fresh.gpuPassProfiling; gpuQueueDepth = fresh.gpuQueueDepth; movement = fresh.movement; cloudSync = fresh.cloudSync
        AVPLog.log("Ajustes: valores por defecto")
    }

    private static func makeDefaults() -> AVPSettings { AVPSettings() }

    /// First Apple Vision Pro (M2) is RealityDevice14,x; a later one is taken as an M5. Unknown: M2.
    static let isM5: Bool = {
        for name in ["hw.machine", "hw.model"] {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { continue }
            var buf = [CChar](repeating: 0, count: size)
            guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { continue }
            let m = String(cString: buf)
            if m.contains("RealityDevice14") { return false }
            if m.contains("RealityDevice") { return true }
        }
        return ProcessInfo.processInfo.physicalMemory >= 24 * 1024 * 1024 * 1024
    }()

    // MARK: Derived

    /// The per-eye render size the OpenVR shim reports (KLVR_EYE_SIZE): the percentage of the
    /// native size, rounded to a multiple of 96 (what the game's render targets tile best at; the
    /// default 90 % gives the validated 2784x2208).
    var eyeSize: (width: Int, height: Int) {
        let p = max(0.5, min(1.3, renderPercent / 100))
        func r(_ v: Int) -> Int { max(96, Int((Double(v) * p / 96).rounded()) * 96) }
        return (r(Self.nativeEye.width), r(Self.nativeEye.height))
    }

    /// The game renders with its own MSAA 4x on both engines: that is the reference picture, and with an MSAA scene
    /// target every eye pass (effects and particles included) gets Klepton's foveation map (kl_gpu_time.m), which a
    /// 1x game could not give (build 19: colour-only eye passes landed unfoveated on a foveated picture).
    /// VPKTAA is now periphery-only: phase 1 is a spatial reconstruction in the compositor's unwarp
    /// (kl_eye_recon, KL_CP_RECON) where the foveated eye is magnified. The temporal VPKTAA (KleptonTAA, 1x game,
    /// jitter) stays off until it has a linearised depth and camera motion from depth + pose.
    var temporalTAA: Bool { false }
    var reconActive: Bool { vpktaa && foveation != .off }
    var gameMSAA: Int { temporalTAA ? 0 : 4 }
    /// The periphery's shading rate for the M2/M5 presets: 10 % (the P.T. setting) to 65 % (an M5 has room for it).
    static let presetPeripheryRange: ClosedRange<Double> = 0.10...0.65
    var presetPeriphery: Double { min(Self.presetPeripheryRange.upperBound, max(Self.presetPeripheryRange.lowerBound, periphery)) }

    /// The Steam language name the game is started with: the system's when Alyx has its text,
    /// else English. Voices are always English (Alyx ships English voices only).
    func gameLanguage(gameDir: URL?) -> (name: String, reason: String) {
        guard systemLanguage else { return ("english", "opción desactivada") }
        let pref = Locale(identifier: Locale.preferredLanguages.first ?? "en-US")
        let code = (pref.language.languageCode?.identifier ?? "en").lowercased()
        let region = (pref.region?.identifier ?? "").uppercased()
        let latam: Set<String> = ["MX", "AR", "CO", "CL", "PE", "VE", "UY", "PY", "BO", "EC", "GT", "CR", "PA", "DO", "HN", "NI", "SV", "PR", "CU", "US", "419"]
        let script = pref.language.script?.identifier ?? ""
        let name: String?
        switch code {
        case "en": name = "english"
        case "es": name = latam.contains(region) ? "latam" : "spanish"
        case "fr": name = "french"
        case "de": name = "german"
        case "it": name = "italian"
        case "ja": name = "japanese"
        case "ko": name = "koreana"
        case "ru": name = "russian"
        case "pl": name = "polish"
        case "pt": name = region == "BR" ? "brazilian" : "portuguese"
        case "zh": name = (script == "Hant" || ["TW", "HK", "MO"].contains(region)) ? "tchinese" : "schinese"
        case "uk": name = "ukrainian"
        case "tr": name = "turkish"
        case "th": name = "thai"
        case "cs": name = "czech"
        case "nl": name = "dutch"
        case "hu": name = "hungarian"
        default: name = nil
        }
        guard let name else { return ("english", "sistema en '\(code)', no es un idioma de Steam") }
        if name == "english" { return ("english", "sistema en inglés") }
        // Alyx's text languages (Steam store page). Its localisation lives inside the VPKs, so the loose files under
        // hlvr/resource said nothing (build 5 fell back to English with Spanish available).
        let alyx: Set<String> = ["english", "spanish", "latam", "french", "german", "italian", "japanese", "koreana",
                                 "russian", "polish", "brazilian", "portuguese", "schinese", "tchinese", "ukrainian",
                                 "turkish", "thai", "czech", "dutch", "hungarian"]
        if !alyx.contains(name) { return ("english", "el juego no incluye '\(name)'") }
        _ = gameDir
        return (name, "idioma del sistema")
    }

    // MARK: Writing the config (every launch)

    struct ConfigPaths {
        let gameDir: URL
        let configDir: URL
        let dataDir: URL
        let pipelines: URL
    }

    /// The convars the app forces, with their values (launch arguments and the Lua re-apply).
    func forcedConvars() -> [(String, String)] {
        var c: [(String, String)] = [
            ("vr_fidelity_level_auto", dynamicResolution ? "1" : "0"),
            ("vr_msaa", String(gameMSAA)),
            ("vr_symmetric_fov", "0"),
            ("r_texture_stream_max_resolution", String(textureCap)),
            ("r_texture_pool_size", String(texturePoolMB)),
            ("r_texture_budget_dynamic", "0"),
            ("r_texture_stream_resolution_bias_min", "1.0"),
            ("r_texture_stream_throttle_count", "6"),
            ("r_texture_stream_throttle_amount", "20"),
        ]
        if !dynamicResolution { c.append(("vr_fidelity_level", "0")) }
        return c + effectsConvars
    }

    /// Game effects whose GPU cost does not follow the eye resolution (build 26 log: 90 % -> 70 % of the eye size gave
    /// ~3-5 of 22-27 ms), enforced like the rest (launch arguments, the Lua re-apply, the fidelity table's columns,
    /// video2.txt). The fidelity table alone did not rule them: the build 26 run read sc_disable_spotlight_shadows 0
    /// back (KLTAB) with the table saying 1, so they are forced here too. An M2 drops what Quest-class headsets never
    /// pay for; an M5 keeps it.
    ///  - r_ssao: the app's «SSAO» setting (`ssao`), on by default on every headset (build 28: fidelity is kept;
    ///    performance is taken from resolution, foveation and the engine, not from effects).
    ///  - r_post_bloom: the bloom chain is fixed-size (1024², 512², 256², 128² RG11B10F, ~16 tiny passes) and part of
    ///    Alyx's look: kept.
    ///  - sc_disable_spotlight_shadows 0: the flashlight's and the spotlights' shadows stay (the table said 1).
    ///  - r_high_quality_shadows: softer shadow filtering, per shaded pixel: off on M2, on on M5.
    ///  - sun cascades: the video settings' low values (3 texels per unit, no second cascade) on both.
    ///  - vr_shadow_map_culling 1: shadow casters outside the view are not drawn into the shadow maps (Valve's
    ///    default; forced so a saved config cannot turn it off).
    var effectsConvars: [(String, String)] {
        let m5 = Self.isM5
        return [
            ("r_ssao", ssao ? "1" : "0"),
            ("r_post_bloom", "1"),
            ("sc_disable_spotlight_shadows", "0"),
            ("r_high_quality_shadows", m5 ? "1" : "0"),
            ("vr_single_light_fast_path_sun_cascade_0_texels_per_world", "3"),
            ("vr_single_light_fast_path_sun_cascade_1_texels_per_world", "0"),
            ("vr_shadow_map_culling", "1"),
        ]
    }
    private func effect(_ name: String) -> String { effectsConvars.first(where: { $0.0 == name })?.1 ?? "0" }

    /// Writes the four files into `p.configDir`. Returns the env lines (also applied with setenv).
    @discardableResult
    func writeConfig(_ p: ConfigPaths) throws -> [(String, String)] {
        let fm = FileManager.default
        try fm.createDirectory(at: p.configDir, withIntermediateDirectories: true)
        let klfz = p.dataDir.appendingPathComponent("klfz", isDirectory: true)
        try fm.createDirectory(at: klfz, withIntermediateDirectories: true)
        // The game's own Vulkan device settings, for warming the pipeline cache before the game
        // starts; the headset's own record replaces it from the second launch.
        let info = klfz.appendingPathComponent("device-info.json")
        if !fm.fileExists(atPath: info.path), let bundled = Bundle.main.url(forResource: "device-info", withExtension: "json") {
            try? fm.copyItem(at: bundled, to: info)
        }

        let lang = gameLanguage(gameDir: p.gameDir)
        let eye = eyeSize
        var args = forcedConvars().map { "+\($0.0) \($0.1)" }.joined(separator: " ")
        args += " +log_verbosity VR max -condebug -language \(lang.name)"

        var env: [(String, String)] = [
            ("KL_ALYX_PROFILE_ARGS", args),
            ("KLVR_EYE_SIZE", "\(eye.width),\(eye.height)"),
            ("KL_DISPLAY_HZ", String(refreshHz)),
            ("KL_GUEST_PACE_HZ", halfRate ? String(refreshHz / 2) : "0"),
            // Klepton's encoder merging is MoltenVK's (MSAA scene chunks). VPKEngine merges same-target passes in its
            // own frame compiler, and now that its queue is watched those hooks would hold its encoders open across
            // its fences: off for VPKEngine.
            ("KL_VK_MERGE", engine == .vpkengine ? "0" : "1"),
            ("KL_VK_MERGE_VIS", engine == .vpkengine ? "0" : "1"),
            ("KLVR_PACE_FALLBACK", halfRate ? "1" : "0"),   // 50 fps on 100 Hz when the GPU fits, else 33.3
            ("KL_LOG_TAG", engine.rawValue),
            ("KL_CP_QUALITY", "0.40"),
            ("MVK_CONFIG_USE_MTLHEAP", "0"),
            ("KL_GUEST_BIGALLOC_MMAP", "1048576"),
            ("KL_HANDS", "0"),
            ("KL_MEM_TOTAL_MB", "16384"),
            ("KL_ALYX_NEWPLAYER_ARGS", "+hlvr_movetype_default \(movement.rawValue)"),
            ("KL_VK_FOZ_REPLAY", "\(p.pipelines.path):\(klfz.path)"),
            ("KL_VK_FOZ_REPLAY_BLOCK", "1"),
            ("KL_VK_FOZ_THREADS", "6"),
            ("KL_VK_FOZ_RECORD", "auto"),
            ("KL_VK_DEVICE_INFO", "auto"),
            ("KL_VK_CENSUS", "1"),
            ("KL_VPKTAA", temporalTAA ? "1" : "0"),
            ("KL_VK_CLEAR_NEW", engine == .moltenvk ? "0" : "1"),   // VisionQuestPro's new-image clear: not in Glovebox's setup
            ("KL_VPKTAA_PCT", String(format: "%.0f", vpktaaPercent)),
            ("KL_VPKTAA_SHARP", String(format: "%.2f", vpktaaSharpness)),
            ("VPVK_ANISO", String(anisotropy)),
            ("VPVK_FORCE_1X", temporalTAA ? "1" : "0"),
            ("VPVK_MOTION", temporalTAA ? "1" : "0"),
            ("KL_CP_RECON", reconActive ? "1" : "0"),
            ("KL_CP_RECON_PCT", String(format: "%.0f", vpktaaPercent)),
            ("KL_CP_RECON_SHARP", String(format: "%.2f", vpktaaSharpness)),
            ("VPVK_TEXTURE_CAP", String(textureCap)),
            ("KL_FPS_HUD", showFps ? "1" : "0"),
            ("KL_CAPTURE", (diagCaptures || engine == .vpkengine) ? "1" : "0"),
            ("VP_FRAMES_IN_FLIGHT", String(gpuQueueDepth)),
            ("KL_CP_SKIP_SAME", composeNewOnly ? "1" : "0"),
            // Build 29: vertex amplification OFF (logs 20/2_6: the right eye was rasterized shrunk into a corner and the
            // overlay pass faulted the GPU). Kept off whatever the stored setting says until it is fixed in VPKEngine.
            ("VPVK_AMPLIFY", "0"),
            ("VPVK_FETCH_NATIVE", "0"),
            ("VP_CB_ORDER", trackedOrder ? "2" : "1"),
            ("VP_EXCL_TIMING", "1"),
        ]
        // VPKTAA inputs not usable yet (build 17 log): VPKEngine's motion vectors are all zero (its "eye frame"
        // restarts at every depth-clearing multiview pass, 4-7 per game frame, so no draw ever finds last frame's
        // data) yet are flagged as full screen motion, which turns the reprojection OFF; and the eye depth needs a
        // Source 2 linearisation (viewport depth 0.05..0.95, z = 0.95 - 0.0375/d) that VPKTAA does not have. Until
        // both are fixed VPKTAA runs rotation-only, and the motion targets, motion pipeline variants and the
        // per-frame depth snapshot (a 61 MB copy with a CPU wait on the frame worker) are not paid for.
        if temporalTAA {
            env += [("KL_VPKTAA_DEPTH", "0")]
        }
        // Foveation: Klepton's rasterization-rate map (kl_gpu_time.m), given per Metal render pass to every pass with
        // an MSAA eye-size target. At 1x (build 19) only layered depth passes could be told apart and the colour-only
        // eye passes landed unfoveated on a foveated picture; with the game's MSAA 4x on every engine, every scene
        // pass carries the MSAA target, as in MoltenVK's validated runs.
        let foveationUsable = gameMSAA >= 4
        switch foveationUsable ? foveation : .off {
        case .off:
            env.append(("KL_VRR", "0"))
        case .m2, .m5:
            env += [("KL_VRR", "1"), ("KL_VRR_MAP", "wide"), ("KL_VRR_EDGE", String(format: "%.3f", presetPeriphery)),
                    ("KL_VRR_WIDE_DEG", String(format: "%.0f", wideDegrees))]
        case .custom:
            env += [("KL_VRR", "1"), ("KL_VRR_MAP", "custom"),
                    ("KL_VRR_INNER", String(format: "%.3f", sharpZone)),
                    ("KL_VRR_OUTER", String(format: "%.3f", min(0.95, sharpZone + transition))),
                    ("KL_VRR_EDGE", String(format: "%.3f", periphery))]
        }
        // Build 27: the foveated passes' render target is the rate map's physical size (Apple's model; kl_gpu_time.m
        // KL_VRR_PHYS): their clears, MSAA/depth resolves, loads and stores covered the whole eye size (2784x2208)
        // though only the physical 36 % is drawn and shown. KL_VRR_PHYS_POST does the same for the unfoveated eye
        // post passes (tonemap...): an A/B switch, off until a run shows the picture intact with it.
        if foveationUsable && foveation != .off {
            // Build 29: OFF. Logs 20/2_6: outside the physical area the eye textures kept a stale unfoveated frame that
            // the post chain and the compositor mixed in (picture inside a picture, black blocks), and the foveated
            // overlay pass faulted the GPU.
            env += [("KL_VRR_PHYS", "0"), ("KL_VRR_PHYS_POST", "0")]
        }
        // Captures (eye pictures as PNG at guest frames 120/600/1200) and a per-pass dump of one in-game frame: always on
        // while VPKEngine's picture is being validated. Core frame 6000 is ~35 s after the first picture (frame 540 in
        // build 19, ~150 core frames per second); 600 fell inside the loading screen.
        if (diagCaptures || engine == .vpkengine), let logs = AVPFolder.shared.logs {
            env += [("KL_CAPTURE_DIR", logs.path), ("VP_DUMP_FRAME", "6000"), ("VP_DUMP_DIR", logs.path)]
        }
        // GPU time per render pass ([passes] in the boot log, kl_gpu_time.m KL_GPU_PASSES), exclusive time grouped by
        // what each pass draws into, plus per-kind totals and the GPU idle inside each frame. Build 26 only had windows
        // 75..330 s after the first frame and no run reached them. Build 27: 24-frame windows 5, 15, 30, 50, 80, 120,
        // 180 and 260 s after EVERY scene start (the grid fading out: the menu, then each level after its load), and
        // at 25, 60 and 100 s of wall time as a fallback. Decides the next performance step from measurements.
        if engine == .vpkengine && gpuPassProfiling {
            env += [("KL_GPU_PASSES", "g5,g15,g30,g50,g80,g120,g180,g260,t25,t60,t100"), ("KL_GPU_PASSES_N", "24")]
        }
        if let driver = AVPLaunch.driverPath { env.append(("KL_MVK_DYLIB", driver)) }
        // VPKEngine's persistent pipeline caches (recipes + Metal binary archive) and whether a full prewarm already
        // filled them for this VPVulkan build and this pipeline list (then neither the launcher nor the game replays).
        if engine == .vpkengine {
            let cache = AVPPipelineCache.configure(data: p.dataDir, pipelines: p.pipelines, engine: engine.rawValue)
            env.append(("VP_PIPELINE_CACHE_DIR", cache.dir.path))
            if cache.archiveOff { env.append(("VP_PIPELINE_ARCHIVE", "0")) }
            env.append(("KL_VK_FOZ_GAME_REPLAY", cache.warm ? "0" : "1"))
        } else {
            AVPPipelineCache.current = nil
        }

        // The compositor's statics are read from the environment once per process: a second game start in the same
        // app session (after Salir) must see this launch's values.
        KleptonCompositor.reconRef = max(0.25, min(2, Float(eye.width) / Float(Self.nativeEye.width)))
        KleptonCompositor.setPeripheryRecon(on: reconActive, percent: Float(vpktaaPercent), sharpness: Float(vpktaaSharpness))
        KleptonCompositor.skipSameEnabled = composeNewOnly
        // Round sharp zone (P.T.'s circle) over the wide map: its degrees are the map's (KL_VRR_WIDE_DEG above, 60 when
        // the launch was not M2/M5, as kl_gpu_time.m defaults it).
        let wideMap = foveationUsable && (foveation == .m2 || foveation == .m5)
        KleptonCompositor.setRoundFovea(on: wideMap && roundSharpZone, degrees: Float(wideMap ? wideDegrees.rounded() : 60),
                                        edge: Float(presetPeriphery))
        var text = "# Written by AVP at every launch from the app's settings. Do not edit: the app rewrites it.\n"
        for (k, v) in env { text += "\(k)=\(v)\n" }
        try text.write(to: p.configDir.appendingPathComponent("alyx-env.txt"), atomically: true, encoding: .utf8)
        try videoSettings().write(to: p.configDir.appendingPathComponent("video2.txt"), atomically: true, encoding: .utf8)
        try fidelityTable().write(to: p.configDir.appendingPathComponent("vr_fidelity_levels_override.csv"), atomically: true, encoding: .utf8)
        try convarsLua().write(to: p.configDir.appendingPathComponent("alyx-convars.lua"), atomically: true, encoding: .utf8)
        AVPLog.log("Config: \(p.configDir.path): ojo \(eye.width)x\(eye.height) (\(Int(renderPercent)) %), \(refreshHz) Hz"
                   + (halfRate ? " (juego a \(refreshHz / 2))" : "") + ", res. dinámica \(dynamicResolution) [\(dynamicMin)–\(dynamicMax)], "
                   + "texturas \(texturePoolMB) MB tope \(textureCap), foveado \(foveation) (zona nítida \(Int(wideDegrees))°), VPKTAA periferia \(reconActive) \(Int(vpktaaPercent)) % "
                   + "nitidez \(vpktaaSharpness), MSAA \(gameMSAA), aniso x\(anisotropy), motor \(engine.rawValue), "
                   + "idioma \(lang.name) (\(lang.reason)), movimiento \(movement), FPS \(showFps), capturas \(diagCaptures), "
                   + "cola GPU \(gpuQueueDepth), componer solo imágenes nuevas \(composeNewOnly), amplificación de vértices off (forzada), orden por recursos \(trackedOrder), zona redonda \(roundSharpZone), SSAO \(ssao)")
        return env
    }

    /// video2-visionpro-demo.txt with the app's texture settings.
    func videoSettings() -> String {
        var text = (Bundle.main.url(forResource: "video2-visionpro-demo", withExtension: "txt"))
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "\"video.cfg\"\n{\n}\n"
        func set(_ key: String, _ value: String) {
            let pattern = "(\"setting\\.\(NSRegularExpression.escapedPattern(for: key))\"\\s+\")([^\"]*)\""
            guard let re = try? NSRegularExpression(pattern: pattern) else { return }
            let range = NSRange(text.startIndex..., in: text)
            if let m = re.firstMatch(in: text, range: range), let r = Range(m.range(at: 2), in: text) {
                text.replaceSubrange(r, with: value)
            } else if let end = text.range(of: "}", options: .backwards) {
                text.insert(contentsOf: "\t\"setting.\(key)\"\t\t\"\(value)\"\n", at: end.lowerBound)
            }
        }
        set("r_texture_stream_max_resolution", String(textureCap))
        set("r_texture_stream_resolution_bias_min", "1.000000")
        set("r_texturefilteringquality", anisotropy >= 16 ? "5" : anisotropy >= 8 ? "4" : anisotropy >= 2 ? "3" : "1")
        // The effects the game keeps in its video settings, as forced (effectsConvars).
        set("r_high_quality_shadows", effect("r_high_quality_shadows"))
        set("vr_single_light_fast_path_sun_cascade_0_texels_per_world",
            String(format: "%.6f", Double(effect("vr_single_light_fast_path_sun_cascade_0_texels_per_world")) ?? 3))
        set("vr_single_light_fast_path_sun_cascade_1_texels_per_world",
            String(format: "%.6f", Double(effect("vr_single_light_fast_path_sun_cascade_1_texels_per_world")) ?? 0))
        return text
    }

    /// The fidelity table: one fixed level (scale 1.0: the render size is KLVR_EYE_SIZE), or with
    /// dynamic resolution, levels from `dynamicMin` to `dynamicMax` the game's auto-fidelity moves between.
    func fidelityTable() -> String {
        let header = "hlvr,default,vr_msaa,vr_render_target_scale,min_gpu_memory,min_width,min_height,r_ssao,r_post_bloom,"
            + "sc_disable_spotlight_shadows,r_high_quality_shadows,vr_single_light_fast_path_sun_cascade_0_texels_per_world,"
            + "vr_single_light_fast_path_sun_cascade_1_texels_per_world,\n"
        // The per-level effect columns are the forced effects (the table used to say sc_disable_spotlight_shadows 1).
        let fx = ["r_ssao", "r_post_bloom", "sc_disable_spotlight_shadows", "r_high_quality_shadows",
                  "vr_single_light_fast_path_sun_cascade_0_texels_per_world",
                  "vr_single_light_fast_path_sun_cascade_1_texels_per_world"].map { effect($0) }.joined(separator: ",")
        func row(_ level: Int, _ isDefault: Bool, _ scale: Double) -> String {
            "\(level),\(isDefault ? 1 : 0),\(gameMSAA),\(String(format: "%.2f", scale)),,,,\(fx),\n"
        }
        var out = header
        if dynamicResolution {
            let lo = min(dynamicMin, dynamicMax), hi = max(dynamicMin, dynamicMax)
            let steps = max(1, Int(((hi - lo) / 0.05).rounded()))
            for i in 0...steps {
                let s = lo + (hi - lo) * Double(i) / Double(steps)
                out += row(i, i == steps, s)
            }
        } else {
            out += row(0, true, 1.0)
        }
        return out + "end,,,,,,,,,,,,,\n"
    }

    /// Glovebox's read-back hooks (app-convars.lua) plus the enforcement: at every spawn, and every
    /// 5 s after it, any forced convar the game (Options menu, a saved config, Steam Cloud) changed is set back.
    func convarsLua() -> String {
        var lua = (Bundle.main.url(forResource: "app-convars", withExtension: "lua"))
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        let pairs = forcedConvars().map { "  { \"\($0.0)\", \"\($0.1)\" }," }.joined(separator: "\n")
        lua += """

-- AVP: the app rules over the game. These convars are set back whenever they differ. One this build does not have
-- is reported once (AVPMISSING) and left alone; one the game keeps refusing (a cheat-protected convar) is reported
-- after 3 tries (AVPSTUCK) and no longer retried, instead of a console command every 5 s.
local AVP_FORCED = {
\(pairs)
}
local AVP_SKIP, AVP_TRIES = {}, {}
local function avp_enforce(tag)
  for _, kv in ipairs(AVP_FORCED) do
    if not AVP_SKIP[kv[1]] then
      local ok, raw = pcall(Convars.GetStr, Convars, kv[1])
      if not ok or raw == nil or raw == "" then
        AVP_SKIP[kv[1]] = true; Msg("AVPMISSING " .. kv[1] .. " (not in this build: left alone)\\n")
      else
        local cur = tostring(raw)
        if cur ~= kv[2] and (tonumber(cur) == nil or tonumber(cur) ~= tonumber(kv[2])) then
          local n = (AVP_TRIES[kv[1]] or 0) + 1   -- corrections in a row that did not take
          AVP_TRIES[kv[1]] = n
          if n > 3 then
            AVP_SKIP[kv[1]] = true; Msg("AVPSTUCK " .. kv[1] .. " stays " .. cur .. " (wanted " .. kv[2] .. "): no more retries\\n")
          else
            SendToConsole(kv[1] .. " " .. kv[2]); Msg("AVPFORCE " .. tag .. " " .. kv[1] .. " " .. cur .. " -> " .. kv[2] .. "\\n")
          end
        else
          AVP_TRIES[kv[1]] = 0
        end
      end
    end
  end
end
ListenToGameEvent("player_activate", function()
  avp_enforce("spawn")
  local w = Entities:First()
  if w then w:SetThink(function() avp_enforce("tick"); return 5.0 end, "avpforce", 5.0) end
end, nil)

"""
        return lua
    }

    /// VPKEngine's own settings (vpvk_config_set_* through avp_config.c).
    /// Pause menu "Volver al juego": what can change with the game running. Foveation shape (not on/off: the
    /// hook is installed at start), VPKTAA strength/sharpness, the FPS counter, and VPKEngine's own config.
    func applyLive() {
        // No setenv here: the compositor and the guest read the environment on other threads, and setenv
        // racing getenv is a crash. Each live setting goes straight to its owner.
        KleptonCompositor.fpsHudEnabled = showFps
        KleptonCompositor.skipSameEnabled = composeNewOnly
        KleptonTAA.reloadSettings(percent: Float(vpktaaPercent), sharpness: Float(vpktaaSharpness))
        KleptonCompositor.setPeripheryRecon(on: reconActive, percent: Float(vpktaaPercent), sharpness: Float(vpktaaSharpness))
        switch foveation {
        case .off: break   // on/off needs a restart (the scene-pass hook is installed at start)
        case .m2, .m5: kl_vrr_set(2, -1, -1, Float(presetPeriphery))
        case .custom: kl_vrr_set(0, Float(sharpZone), Float(min(0.95, sharpZone + transition)), Float(periphery))
        }
        // The round sharp zone follows the map: on with the wide map, at its live periphery (degrees stay the launch's).
        if foveation != .off {
            KleptonCompositor.setRoundFovea(on: (foveation == .m2 || foveation == .m5) && roundSharpZone, degrees: nil, edge: Float(presetPeriphery))
        }
        applyToVPKEngine()
        AVPLog.log("Ajustes en vivo: foveado \(foveation), VPKTAA periferia \(reconActive) \(Int(vpktaaPercent)) % nitidez \(vpktaaSharpness), FPS \(showFps), componer solo imágenes nuevas \(composeNewOnly)")
    }

    func applyToVPKEngine() {
        var c = avp_gfx_config()
        c.foveation_mode = Int32(foveation.rawValue)
        c.sharp_zone = Float(sharpZone)
        c.periphery = Float(periphery)
        c.transition = Float(transition)
        c.vpktaa_enabled = temporalTAA ? 1 : 0
        c.vpktaa_percent = Float(vpktaaPercent)
        c.vpktaa_sharpness = Float(vpktaaSharpness)
        c.render_scale = 1
        c.anisotropy = Int32(anisotropy)
        c.force_single_sample = temporalTAA ? 1 : 0
        c.texture_cap = Int32(textureCap)
        let fwd = avp_gfx_config_apply(&c)
        AVPLog.log("Gráficos: ajustes enviados a VPKEngine: \(fwd == 1 ? "sí" : "no (driver no cargado)")")
    }
}
