// AVP: the settings that rule over the game. All of them live in the app (UserDefaults, the
// Settings screen); none is ever read back from a text file. On EVERY launch they are written
// into the config folder (AlyxBoot's configDir) and pushed to VPKEngine, overriding whatever the
// game's own files, its Options menu or Steam Cloud left behind:
//
//   alyx-env.txt                      KEY=VALUE for Klepton / the OpenVR shim / VPKEngine
//   video2.txt                        the game's video settings (from video2-visionpro-demo.txt)
//   vr_fidelity_levels_override.csv   the fidelity table (one fixed level)
//   alyx-convars.lua                  re-applies the forced convars at every spawn and every few seconds
//
// The keys follow Glovebox's packages/alyx/defaults/DEMO.txt and engine/gb/build.py defaults().

import Combine
import Foundation

final class AVPSettings: ObservableObject {
    static let shared = AVPSettings()

    // MARK: Values

    enum Movement: Int, CaseIterable { case teleport = 0, continuousHead = 2, continuousHand = 3 }
    /// Build 35: where the game's VR subtitles sit. Defaults read from the ARM64 libclient.so's ConVar registrations:
    /// `cc_vr_vertical_offset` -6.5 ("Subtitle vertical offset distance (positive is up)", game units), `cc_vr_forward_offset`
    /// 30, `cc_vr_font_size` 0/1/2 = small/med/large (default 1, archived). Forced as absolute values (forcedConvars:
    /// launch arguments + the Lua re-apply), so nothing compounds across maps or launches.
    enum SubtitlePlacement: Int, CaseIterable { case game = 0, higher = 1, eyeLevel = 2, high = 3
        var verticalOffset: String { self == .game ? "-6.5" : self == .higher ? "0" : self == .eyeLevel ? "6" : "12" }
    }
    /// Build 38: cc_vr_font_size 0/1/2. Build 35's large filled the view with a long line; small by default.
    enum SubtitleSize: Int, CaseIterable { case small = 0, medium = 1, large = 2 }

    /// Vision Pro's native per-eye render size (what visionOS asks for at 100 %).
    static let nativeEye = (width: 3072, height: 2464)

    /// Render resolution as a percentage of the native eye size (50...130).
    @Published var renderPercent: Double { didSet { graphicsChanged() } }
    @Published var textureCap: Int { didSet { graphicsChanged() } }        // 1024 | 2048 | 4096
    /// Foveation (on by default): Klepton's KL_VRR_MAP=wide, the user's P.T. map (a round sharp zone of `wideDegrees`
    /// at full rate, centred 10° below each eye's forward axis) with the periphery at `periphery` (10 % to 65 %).
    /// The old M2/M5/custom presets were the same map (M5 only allowed a better periphery) and a rectangular custom
    /// map nobody could reason about: build 32 keeps one switch and two numbers.
    @Published var foveationOn: Bool { didSet { graphicsChanged() } }
    /// The sharp zone's width in degrees (30...70, PTVisionPro's 60 by default); the rest at `periphery`.
    @Published var wideDegrees: Double { didSet { graphicsChanged() } }
    @Published var periphery: Double { didSet { graphicsChanged() } }      // 0.1...0.65 shading rate at the edge
    @Published var vpktaa: Bool { didSet { graphicsChanged() } }
    @Published var vpktaaPercent: Double { didSet { graphicsChanged() } }  // 0...100
    @Published var vpktaaSharpness: Double { didSet { graphicsChanged() } } // 0...1
    @Published var anisotropy: Int { didSet { graphicsChanged() } }        // 0, 2, 4, 8, 16
    @Published var systemLanguage: Bool { didSet { save() } }
    @Published var showFps: Bool { didSet { save() } }
    /// Ambient occlusion (r_ssao). On by default on every headset: fidelity is kept, performance comes from resolution.
    @Published var ssao: Bool { didSet { graphicsChanged() } }
    /// Build 53: the game's MSAA (0 off, 2, 4). Foveation needs an MSAA scene target to find the eye passes, so with
    /// MSAA off it is not applied.
    @Published var msaa: Int { didSet { graphicsChanged() } }
    /// Build 27 (VPKEngine 0031): command buffers wait only on the previous ones they really depend on (VP_CB_ORDER=2)
    /// instead of all of them (0029, VP_CB_ORDER=1). Logs 23: a whole session with it, no hang, no vertex explosion,
    /// out_of_order=0 → on by default since build 32. If vertex explosions come back, turn it off.
    @Published var trackedOrder: Bool { didSet { save() } }
    /// Diagnostic captures: eye PNGs at fixed frames, L3+R3 on-glitch captures and pass dumps (KL_CAPTURE).
    @Published var diagCaptures: Bool { didSet { save() } }
    /// Build 27: per-pass GPU timing windows (KL_GPU_PASSES, kl_gpu_time.m) + VPKEngine's exclusive per-encoder
    /// timing (VP_EXCL_TIMING). Off by default since build 32: sample buffers on 28-120 encoders per frame are not free.
    @Published var gpuPassProfiling: Bool { didSet { save() } }
    @Published var movement: Movement { didSet { save() } }
    @Published var subtitles: SubtitlePlacement { didSet { save() } }
    @Published var subtitleSize: SubtitleSize { didSet { save() } }
    /// Build 38 (A/B for a flicker report on B36b): the subtitle pass (sRGB eye view, no depth) gets the rate map
    /// (KL_VRR_SRGB_1X). Off = drawn in screen space over the foveated layout (B35: misplaced and sheared).
    @Published var subtitleFoveation: Bool { didSet { save() } }
    @Published var cloudSync: Bool { didSet { save() } }
    /// Build 33: the player's fingers follow the headset's hand tracking (KL_HANDS=1, kl_ovrp_set_finger_curls →
    /// the OpenVR skeleton), as Valve's Index controllers animate them; off = fingers from the buttons only and no
    /// hand-tracking permission asked.
    @Published var handFingers: Bool { didSet { save() } }
    /// VPKEngine vertex amplification (VPVK_AMPLIFY=1): both eyes from one vertex pass (Metal vertex amplification)
    /// instead of multiview by instancing. Validated in build 33 (Logs_Alyx_2_8/2_9): both eyes and the foveation
    /// correct, no GPU faults, the scene's vertex time 8-12 ms -> ~4 ms. ON by default since build 34 (new key
    /// avp.amplify so every install gets it); off = instancing, the build 32 behaviour.
    @Published var amplify: Bool { didSet { save() } }
    /// Build 36 (A/B, off): the unfoveated eye post passes (tonemap, bloom composite: fullscreen, texel for texel, no
    /// depth) get their render target constrained to the rate map's physical size (KL_VRR_PHYS_POST, kl_gpu_time.m):
    /// about half their tiles (1.3 + 1.3 ms a frame at 48 % physical). Outside the physical area the eye image stays
    /// what it was (black: the scene's clear tonemapped by the first, full-area pass). Diagnostic until a run shows
    /// the picture intact; the foveated passes' own version (KL_VRR_PHYS) broke the picture in build 29 and stays off.
    @Published var postPhysical: Bool { didSet { save() } }
    /// Build 37: the compositor samples the game's own eye image (KLVR_EYE_DIRECT=1, klvr_vk_submit.cpp) instead of
    /// a copy of each eye into a platform image. Build 40: OFF and refused by kl_vulkan when the game submits one
    /// image for every stage (Alyx does: Logs_Alyx_28/29 flickered and juddered with it on). Kept for a game that cycles.
    @Published var eyeDirect: Bool { didSet { save() } }
    /// Build 38: player height offset in cm (negative = Alyx lower: for sitting down, or a floor origin that came out
    /// too low under the player). KLVR_HEIGHT_OFFSET, every tracked pose the game sees; live.
    @Published var heightOffsetCm: Double { didSet { save() } }
    /// Build 39: the game's occlusion queries measured (VPKEngine 0037, Metal visibility results) instead of
    /// "always visible": Source 2 then skips what its occlusion test found hidden (r_occlusion_culling 1).
    /// Off = every query reads visible, the behaviour up to build 38 (VPVK_OCCLUSION).
    @Published var occlusionQueries: Bool { didSet { save() } }
    /// Build 43/44: the refresh rate the OpenVR shim tells Alyx (Prop_DisplayFrequency). Alyx steps its clock by
    /// 1/this per frame and fixes its tick interval to 1/this at map load (Logs_Alyx_32/3_2/2_11). `measured` (the
    /// default) = automatic since build 44: the pace governor's current rate, the base while loading
    /// (klvr_game_hz); the fixed values are tests (KLVR_REPORT_HZ_FIXED): 90 runs the game at 55 % speed.
    enum ReportedHz: Int, CaseIterable { case measured = 0, fixed50 = 1, fixed90 = 2
        var env: String { self == .fixed50 ? "50" : self == .fixed90 ? "90" : "0" }
    }
    @Published var reportedHz: ReportedHz { didSet { save() } }
    /// Build 45 (Logs_Alyx_34/2_12): the guest is released `lead` ms before its refresh so it builds the next frame on
    /// the CPU while the GPU finishes the current one (SteamVR's running start). Off = the B44 pacing, where the GPU
    /// idled ~5 ms at the start of every frame whatever the resolution (KL_GUEST_PACE_LEAD_MS).
    @Published var runningStart: Bool { didSet { save() } }
    /// Build 46: the automatic A/B performance test (KL_ABTEST=1, kl_gpu_time.m): ~2 min after the game loads, with the
    /// player still, VPKEngine's runtime optimisations (patch 0038) and the eye-copy trim are measured on and off, then
    /// each heavy shader is left out once; what saves stays on for the session and everything goes to the log. While on,
    /// the compositor's diagnostic captures stop after guest frame 120 (each stalls ~250 ms).
    @Published var abTest: Bool { didSet { save() } }
    /// Build 53: graphics engine for an A/B run. VPKEngine (VPVulkan) is the default; MoltenVK (bundled) is a test: none
    /// of VPKEngine's patches apply (measured occlusion, amplification, constant tables, exclusive GPU time).
    enum Engine: String, CaseIterable { case vpkengine, moltenvk }
    @Published var engine: Engine { didSet { save() } }
    /// Build 53: settings layout version. Older saved settings are wiped once so every validated value is the default
    /// (the options left out of the menu keep their default for good).
    static let schema = 53
    /// Build 53: picture presets. Changing any picture setting by hand switches to Personalizado (custom).
    enum Preset: String, CaseIterable { case m2, m5, custom }
    @Published var preset: Preset { didSet { if preset != oldValue, !loading { applyPreset() }; save() } }
    private var applyingPreset = false
    private func graphicsChanged() {
        if !loading && !applyingPreset && preset != .custom { preset = .custom }
        save()
    }
    /// M2: the values of the user's Logs_Alyx_40 run with the resolution at 70 %. M5: not measured yet (same as M2).
    func applyPreset() {
        guard preset != .custom else { return }
        applyingPreset = true
        renderPercent = 70; textureCap = 2048; foveationOn = true; wideDegrees = 70; periphery = 0.10
        vpktaa = true; vpktaaPercent = 100; vpktaaSharpness = 1.0; anisotropy = 16; msaa = 4; ssao = true
        applyingPreset = false
    }
    /// Keys the B53 wipe and Restablecer keep (paths, signing, preparation state).
    private static let keptKeys: Set<String> = ["avp.folderBookmark", "avp.signatureVariant", "avp.prepared"]

    // Fixed since build 32 (they used to be settings; every validated value is now the only value):
    /// 12 command buffers in flight (build 24 orders them; 3 was the build-23 A/B test).
    static let gpuQueueDepth = 12
    /// The compositor composes only new pictures (build 26/27, KL_CP_SKIP_SAME): 3.3 ms of GPU per frame, no downside.
    static let composeNewOnly = true
    /// The guest is told 90 Hz (Klepton's pin: Steam Link's VR client dereferences a null frametime container on a
    /// measured rate) and paced to half of it; the pacer takes the measured display rate (100 Hz on the Vision Pro),
    /// so the game runs at 50 fps when the GPU fits, else 33 (KLVR_PACE_FALLBACK). The old 90/100 Hz picker only
    /// changed what the game was told, never what the headset does.
    static let guestHz = 90
    /// The round sharp zone (P.T.'s circle, build 27) is the sharp zone: the rectangular one is gone.
    static let roundSharpZone = true
    /// MSAA scene targets resolve from tile (VPKEngine 0034, VP_MSAA_TILE=1). Logs 23: never applied yet
    /// (tile_rejected=2 every frame, see 0035's gpu.msaa rejected); harmless meanwhile.
    static let msaaOnTile = true

    private var loading = true

    private init() {
        let d = UserDefaults.standard
        if d.integer(forKey: "avp.schema") < Self.schema {
            // Personal choices (language, movement, subtitles, height, fingers, cloud, FPS) survive the wipe.
            let personal: Set<String> = ["avp.sysLang", "avp.movement", "avp.subtitles", "avp.subSize", "avp.subFov",
                                         "avp.cloudSync", "avp.handFingers", "avp.heightCm", "avp.showFps"]
            for k in d.dictionaryRepresentation().keys where k.hasPrefix("avp.") && !Self.keptKeys.contains(k)
                && !personal.contains(k) {
                d.removeObject(forKey: k)
            }
            d.set(Self.schema, forKey: "avp.schema")
        }
        preset = Preset(rawValue: d.string(forKey: "avp.preset") ?? "") ?? (Self.isM5 ? .m5 : .m2)
        renderPercent = d.object(forKey: "avp.renderPercent") as? Double ?? 90
        textureCap = d.object(forKey: "avp.texCap") as? Int ?? 2048
        // Build 32: the M2/M5/custom picker (avp.fov2: 0 off, 1 M2, 2 M5, 3 custom) becomes one switch.
        foveationOn = d.object(forKey: "avp.fovOn") as? Bool ?? ((d.object(forKey: "avp.fov2") as? Int ?? 1) != 0)
        wideDegrees = min(70, max(30, d.object(forKey: "avp.fovWideDeg") as? Double ?? 60))
        periphery = min(Self.peripheryRange.upperBound, max(Self.peripheryRange.lowerBound, d.object(forKey: "avp.fovPeriphery2") as? Double ?? 0.10))
        vpktaa = d.object(forKey: "avp.vpktaa") as? Bool ?? true
        vpktaaPercent = d.object(forKey: "avp.reconPercent") as? Double ?? 80
        vpktaaSharpness = d.object(forKey: "avp.reconSharp") as? Double ?? 1.0
        anisotropy = d.object(forKey: "avp.aniso") as? Int ?? 16
        systemLanguage = d.object(forKey: "avp.sysLang") as? Bool ?? true
        showFps = d.object(forKey: "avp.showFps") as? Bool ?? false
        ssao = d.object(forKey: "avp.ssao") as? Bool ?? true
        msaa = [0, 2, 4].contains(d.integer(forKey: "avp.msaa")) && d.object(forKey: "avp.msaa") != nil ? d.integer(forKey: "avp.msaa") : 4
        trackedOrder = d.object(forKey: "avp.cbOrder2c") as? Bool ?? true
        diagCaptures = d.object(forKey: "avp.diagCaptures") as? Bool ?? false
        gpuPassProfiling = d.object(forKey: "avp.gpuPasses2") as? Bool ?? false
        movement = Movement(rawValue: d.object(forKey: "avp.movement") as? Int ?? 3) ?? .continuousHand
        subtitles = SubtitlePlacement(rawValue: d.object(forKey: "avp.subtitles") as? Int ?? 2) ?? .eyeLevel
        cloudSync = d.object(forKey: "avp.cloudSync") as? Bool ?? true
        handFingers = d.object(forKey: "avp.handFingers") as? Bool ?? true
        amplify = d.object(forKey: "avp.amplify") as? Bool ?? true
        postPhysical = d.object(forKey: "avp.postPhys") as? Bool ?? true   // B53: ON (B39-B52 runs: no visual fault)
        eyeDirect = d.object(forKey: "avp.eyeDirect2") as? Bool ?? false   // build 40: OFF (Alyx renders into one image)
        heightOffsetCm = d.object(forKey: "avp.heightCm") as? Double ?? 0
        occlusionQueries = d.object(forKey: "avp.occlusion") as? Bool ?? true
        reportedHz = ReportedHz(rawValue: d.object(forKey: "avp.reportHz") as? Int ?? 0) ?? .measured
        runningStart = d.object(forKey: "avp.runStart") as? Bool ?? true
        abTest = d.object(forKey: "avp.abTest") as? Bool ?? false
        engine = Engine(rawValue: d.string(forKey: "avp.engine") ?? "") ?? .vpkengine
        subtitleSize = SubtitleSize(rawValue: d.object(forKey: "avp.subSize") as? Int ?? 0) ?? .small
        subtitleFoveation = d.object(forKey: "avp.subFov") as? Bool ?? true
        loading = false
        if preset != .custom { applyPreset() }   // a preset's values always win over stale saved ones
    }

    private func save() {
        guard !loading else { return }
        let d = UserDefaults.standard
        d.set(renderPercent, forKey: "avp.renderPercent")
        d.set(textureCap, forKey: "avp.texCap")
        d.set(foveationOn, forKey: "avp.fovOn")
        d.set(wideDegrees, forKey: "avp.fovWideDeg")
        d.set(periphery, forKey: "avp.fovPeriphery2")
        d.set(vpktaa, forKey: "avp.vpktaa")
        d.set(vpktaaPercent, forKey: "avp.reconPercent")
        d.set(vpktaaSharpness, forKey: "avp.reconSharp")
        d.set(anisotropy, forKey: "avp.aniso")
        d.set(systemLanguage, forKey: "avp.sysLang")
        d.set(showFps, forKey: "avp.showFps")
        d.set(ssao, forKey: "avp.ssao")
        d.set(msaa, forKey: "avp.msaa")
        d.set(trackedOrder, forKey: "avp.cbOrder2c")
        d.set(diagCaptures, forKey: "avp.diagCaptures")
        d.set(gpuPassProfiling, forKey: "avp.gpuPasses2")
        d.set(movement.rawValue, forKey: "avp.movement")
        d.set(subtitles.rawValue, forKey: "avp.subtitles")
        d.set(cloudSync, forKey: "avp.cloudSync")
        d.set(handFingers, forKey: "avp.handFingers")
        d.set(amplify, forKey: "avp.amplify")
        d.set(postPhysical, forKey: "avp.postPhys")
        d.set(eyeDirect, forKey: "avp.eyeDirect2")
        d.set(heightOffsetCm, forKey: "avp.heightCm")
        d.set(occlusionQueries, forKey: "avp.occlusion")
        d.set(reportedHz.rawValue, forKey: "avp.reportHz")
        d.set(runningStart, forKey: "avp.runStart")
        d.set(abTest, forKey: "avp.abTest")
        d.set(engine.rawValue, forKey: "avp.engine")
        d.set(preset.rawValue, forKey: "avp.preset")
        d.set(Self.schema, forKey: "avp.schema")
        d.set(subtitleSize.rawValue, forKey: "avp.subSize")
        d.set(subtitleFoveation, forKey: "avp.subFov")
    }

    func resetToDefaults() {
        for k in UserDefaults.standard.dictionaryRepresentation().keys where k.hasPrefix("avp.") && !Self.keptKeys.contains(k) {
            UserDefaults.standard.removeObject(forKey: k)
        }
        let fresh = AVPSettings.makeDefaults()
        renderPercent = fresh.renderPercent; textureCap = fresh.textureCap
        foveationOn = fresh.foveationOn; wideDegrees = fresh.wideDegrees; periphery = fresh.periphery
        vpktaa = fresh.vpktaa; vpktaaPercent = fresh.vpktaaPercent; vpktaaSharpness = fresh.vpktaaSharpness
        anisotropy = fresh.anisotropy; systemLanguage = fresh.systemLanguage; showFps = fresh.showFps; ssao = fresh.ssao; msaa = fresh.msaa
        trackedOrder = fresh.trackedOrder; diagCaptures = fresh.diagCaptures; gpuPassProfiling = fresh.gpuPassProfiling
        movement = fresh.movement; subtitles = fresh.subtitles; cloudSync = fresh.cloudSync; handFingers = fresh.handFingers; amplify = fresh.amplify
        postPhysical = fresh.postPhysical; eyeDirect = fresh.eyeDirect; heightOffsetCm = fresh.heightOffsetCm; occlusionQueries = fresh.occlusionQueries
        subtitleSize = fresh.subtitleSize; subtitleFoveation = fresh.subtitleFoveation
        reportedHz = fresh.reportedHz; runningStart = fresh.runningStart; abTest = fresh.abTest; engine = fresh.engine
        preset = fresh.preset
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
    /// Foveation needs an MSAA scene target to find the eye passes (kl_gpu_time.m): off with MSAA off.
    var foveationUsable: Bool { gameMSAA >= 2 && foveationOn }
    var reconActive: Bool { vpktaa && foveationUsable }
    var gameMSAA: Int { temporalTAA ? 0 : msaa }
    /// The periphery's shading rate: 10 % (the P.T. setting) to 65 % (an M5 has room for it).
    static let peripheryRange: ClosedRange<Double> = 0.10...0.65
    /// The texture streaming pool for the chosen maximum texture size (it used to be a separate stepper nobody could
    /// relate to the size): 2048 → the validated 2560 MB.
    var texturePoolMB: Int { textureCap >= 4096 ? 2816 : textureCap >= 2048 ? 2560 : 1536 }

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
            ("vr_fidelity_level_auto", "0"),
            ("vr_msaa", String(gameMSAA)),
            ("vr_symmetric_fov", "0"),
            ("r_texture_stream_max_resolution", String(textureCap)),
            ("r_texture_pool_size", String(texturePoolMB)),
            ("r_texture_budget_dynamic", "0"),
            ("r_texture_stream_resolution_bias_min", "1.0"),
            ("r_texture_stream_throttle_count", "6"),
            ("r_texture_stream_throttle_amount", "20"),
        ]
        c.append(("vr_fidelity_level", "0"))
        // Build 35: the VR subtitle panel's height and size (SubtitlePlacement). «As the game» forces nothing: the
        // game's default is -6.5 and a negative value on the command line ("+cvar -6.5") would read as a switch.
        c.append(("cc_vr_font_size", String(subtitleSize.rawValue)))   // build 38: its own setting, any placement
        if subtitles != .game {
            c.append(("cc_vr_vertical_offset", subtitles.verticalOffset))
        }
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
            // Build 31: software occlusion culling (occluded = never visible: no fidelity cost). Forced so a saved
            // config cannot turn it off; AVPMISSING if this build lacks it.
            ("r_occlusion_culling", "1"),
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

        // B53: MoltenVK only when picked AND the launcher really fell back to it (no VPVulkan loaded).
        let vpk = AVPLaunch.driverPath != nil
        var env: [(String, String)] = [
            ("KL_ALYX_PROFILE_ARGS", args),
            ("KLVR_EYE_SIZE", "\(eye.width),\(eye.height)"),
            ("KL_DISPLAY_HZ", String(Self.guestHz)),
            ("KL_GUEST_PACE_HZ", String(Self.guestHz / 2)),
            // B51: 9 ms (was 6). Logs_Alyx_37 [gap]: frames whose main command buffer was committed late left the GPU idle
            // 2-3 ms and overran the 45 fps budget (pictures held 3 refreshes: the judder in menus).
            ("KL_GUEST_PACE_LEAD_MS", runningStart ? "9" : "0"),
            // B51: eye copies trimmed to the foveation map's physical area by default (A/B: +0.4-1.1 ms in all 6 rounds of
            // Logs_Alyx_36 and 2_14, under the noise threshold but never negative).
            ("KL_EYE_TRIM", "1"),
            ("KL_ABTEST", abTest ? "1" : "0"),
            // Klepton's encoder merging is MoltenVK's (MSAA scene chunks). VPKEngine merges same-target passes in its
            // own frame compiler, and now that its queue is watched those hooks would hold its encoders open across
            // its fences: off.
            ("KL_VK_MERGE", vpk ? "0" : "1"),
            ("KL_VK_MERGE_VIS", vpk ? "0" : "1"),
            ("KLVR_PACE_FALLBACK", "1"),   // 50 fps on 100 Hz when the GPU fits, else 33.3
            ("KL_LOG_TAG", vpk ? "vpkengine" : "moltenvk"),
            ("KL_CP_QUALITY", "0.40"),
            ("MVK_CONFIG_USE_MTLHEAP", "0"),
            ("KL_GUEST_BIGALLOC_MMAP", "1048576"),
            // Build 33: hand tracking on for the fingers (KleptonControllers.publishFingers); the Sense controllers
            // keep the pose and the buttons.
            ("KL_HANDS", handFingers ? "1" : "0"),
            ("KL_HANDS_POSE", "0"),   // fingers only: a tracked hand never stands in for a Sense controller
            ("KL_MEM_TOTAL_MB", "16384"),
            ("KL_ALYX_NEWPLAYER_ARGS", "+hlvr_movetype_default \(movement.rawValue)"),
            ("KL_VK_FOZ_REPLAY", "\(p.pipelines.path):\(klfz.path)"),
            ("KL_VK_FOZ_REPLAY_BLOCK", "1"),
            ("KL_VK_FOZ_THREADS", "6"),
            ("KL_VK_FOZ_RECORD", "auto"),
            ("KL_VK_DEVICE_INFO", "auto"),
            ("KL_VK_CENSUS", "1"),
            ("KL_VPKTAA", temporalTAA ? "1" : "0"),
            ("KL_VK_CLEAR_NEW", vpk ? "1" : "0"),   // VisionQuestPro's new-image clear: not in Glovebox's setup
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
            ("KL_CAPTURE", diagCaptures ? "1" : "0"),
            ("VP_FRAMES_IN_FLIGHT", String(Self.gpuQueueDepth)),
            ("KL_CP_SKIP_SAME", Self.composeNewOnly ? "1" : "0"),
            // Build 34: vertex amplification ON by default (validated in Logs_Alyx_2_8/2_9: both eyes and the foveation
            // correct, no GPU faults, scene vertex time 8-12 -> ~4 ms). B29 had it off after B27's faults.
            ("VPVK_AMPLIFY", amplify ? "1" : "0"),
            ("KLVR_EYE_DIRECT", eyeDirect ? "1" : "0"),
            ("KLVR_HEIGHT_OFFSET", String(format: "%.3f", heightOffsetCm / 100)),
            ("KL_VRR_SRGB_1X", "1"),   // build 42: always (B41 log: the A/B toggle left off = the B35 subtitle bug again)
            ("VPVK_OCCLUSION", occlusionQueries ? "1" : "0"),
            ("KLVR_REPORT_HZ_FIXED", reportedHz.env),
            // Build 31: native half fetch back on, alone (B29 turned it off only because it shipped with amplification;
            // the translator's conversion is exact). Logs 22: the scene pass is vertex-bound (vtx 11 ms).
            ("VPVK_FETCH_NATIVE", "1"),
            // Build 31: MSAA scene targets resolve from tile instead of storing every sample (VPKEngine 0034).
            ("VP_MSAA_TILE", Self.msaaOnTile ? "1" : "0"),
            ("VP_CB_ORDER", trackedOrder ? "2" : "1"),
            // VPKEngine 0038/0039 runtime opts at start: bit 0 producer-only fence waits (Logs_Alyx_35: -1.5 ms in the menu at 80 %).
            // B52: off again. No measurable gain on the exclusive GPU time (Logs_Alyx_36/2_14: ~0.2 ms), and late shadows
            // in a level (Logs_Alyx_38) are the symptom a missed ordering would give.
            ("VPVK_RUNTIME_OPTS", "0"),
            // Build 32: exclusive per-encoder timing only with the per-pass profiling (it costs sample buffers on every
            // encoder); gpu.enc detail (tile=/mem= per attachment, VPKEngine 0035) every 3000 core frames (~20 s).
            ("VP_EXCL_TIMING", gpuPassProfiling ? "1" : "0"),
            ("VP_FRAME_DETAIL", "3000"),
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
        if foveationUsable {
            env += [("KL_VRR", "1"), ("KL_VRR_MAP", "wide"), ("KL_VRR_EDGE", String(format: "%.3f", periphery)),
                    ("KL_VRR_WIDE_DEG", String(format: "%.0f", wideDegrees))]
        } else {
            env.append(("KL_VRR", "0"))
        }
        // Build 27: the foveated passes' render target is the rate map's physical size (Apple's model; kl_gpu_time.m
        // KL_VRR_PHYS): their clears, MSAA/depth resolves, loads and stores covered the whole eye size (2784x2208)
        // though only the physical 36 % is drawn and shown. KL_VRR_PHYS_POST does the same for the unfoveated eye
        // post passes (tonemap...): an A/B switch, off until a run shows the picture intact with it.
        if foveationUsable {
            // Build 29: OFF. Logs 20/2_6: outside the physical area the eye textures kept a stale unfoveated frame that
            // the post chain and the compositor mixed in (picture inside a picture, black blocks), and the foveated
            // overlay pass faulted the GPU.
            env += [("KL_VRR_PHYS", "0"), ("KL_VRR_PHYS_POST", postPhysical ? "1" : "0")]
        }
        // Captures (eye pictures as PNG at guest frames 120/600/1200...) and, on L3 + R3, a per-pass dump of the next
        // frame (VP_DUMP_DIR). Build 46: no automatic dump at core frame 6000 any more (VP_DUMP_FRAME): its GPU readback
        // (~300 MB) froze the game ~1.5 s. With the A/B test on, the compositor's captures stop after guest frame 120
        // (KL_CAPTURE_MAX_FRAME): each stalls ~250 ms and would land in the test's measurements.
        if diagCaptures, let logs = AVPFolder.shared.logs {
            env += [("KL_CAPTURE_DIR", logs.path), ("VP_DUMP_DIR", logs.path)]
            env.append(("KL_CAPTURE_MAX_FRAME", abTest ? "120" : "0"))
        }
        // GPU time per render pass ([passes] in the boot log, kl_gpu_time.m KL_GPU_PASSES), exclusive time grouped by
        // what each pass draws into, plus per-kind totals and the GPU idle inside each frame. Build 26 only had windows
        // 75..330 s after the first frame and no run reached them. Build 27: 24-frame windows 5, 15, 30, 50, 80, 120,
        // 180 and 260 s after EVERY scene start (the grid fading out: the menu, then each level after its load), and
        // at 25, 60 and 100 s of wall time as a fallback. Decides the next performance step from measurements.
        if gpuPassProfiling {
            env += [("KL_GPU_PASSES", "g5,g15,g30,g50,g80,g120,g180,g260,t25,t60,t100"), ("KL_GPU_PASSES_N", "24")]
        }
        if let driver = AVPLaunch.driverPath { env.append(("KL_MVK_DYLIB", driver)) }
        // VPKEngine's persistent pipeline caches (recipes + Metal binary archive) and whether a full prewarm already
        // filled them for this VPVulkan build and this pipeline list (then neither the launcher nor the game replays).
        if vpk {
            // The engine configuration the hang quarantine is valid for (AVPPipelineCache: quarantine.key). The values
            // are read back from the env so the signature cannot drift from what VPKEngine actually gets.
            let sigKeys = ["VPVK_AMPLIFY", "VPVK_FETCH_NATIVE", "VP_CB_ORDER", "KL_VRR", "KL_VRR_PHYS", "VPVK_FORCE_1X",
                           "VPVK_MOTION", "VP_FRAMES_IN_FLIGHT", "VP_MSAA_TILE"]
            let signature = sigKeys.map { k in "\(k)=\(env.last { $0.0 == k }?.1 ?? "-")" }.joined(separator: "|")
                + "|msaa=\(gameMSAA)"
            let cache = AVPPipelineCache.configure(data: p.dataDir, pipelines: p.pipelines, engine: "vpkengine",
                                                   engineSignature: signature)
            env.append(("VP_PIPELINE_CACHE_DIR", cache.dir.path))
            if cache.archiveOff { env.append(("VP_PIPELINE_ARCHIVE", "0")) }
            env.append(("KL_VK_FOZ_GAME_REPLAY", cache.warm ? "0" : "1"))
        }

        // The compositor's statics are read from the environment once per process: a second game start in the same
        // app session (after Salir) must see this launch's values.
        KleptonCompositor.reconRef = max(0.25, min(2, Float(eye.width) / Float(Self.nativeEye.width)))
        KleptonCompositor.setPeripheryRecon(on: reconActive, percent: Float(vpktaaPercent), sharpness: Float(vpktaaSharpness))
        KleptonCompositor.skipSameEnabled = Self.composeNewOnly
        // Round sharp zone (P.T.'s circle) over the wide map: its degrees are the map's (KL_VRR_WIDE_DEG above).
        KleptonCompositor.setRoundFovea(on: foveationUsable && Self.roundSharpZone, degrees: Float(wideDegrees.rounded()),
                                        edge: Float(periphery))
        var text = "# Written by AVP at every launch from the app's settings. Do not edit: the app rewrites it.\n"
        for (k, v) in env { text += "\(k)=\(v)\n" }
        try text.write(to: p.configDir.appendingPathComponent("alyx-env.txt"), atomically: true, encoding: .utf8)
        try videoSettings().write(to: p.configDir.appendingPathComponent("video2.txt"), atomically: true, encoding: .utf8)
        try fidelityTable().write(to: p.configDir.appendingPathComponent("vr_fidelity_levels_override.csv"), atomically: true, encoding: .utf8)
        try convarsLua().write(to: p.configDir.appendingPathComponent("alyx-convars.lua"), atomically: true, encoding: .utf8)
        AVPLog.log("Config: \(p.configDir.path): ojo \(eye.width)x\(eye.height) (\(Int(renderPercent)) %), juego a \(Self.guestHz / 2) "
                   + "(o 50/33 según la pantalla), texturas \(texturePoolMB) MB tope \(textureCap), foveado \(foveationOn) (zona nítida "
                   + "\(Int(wideDegrees))°, periferia \(Int((periphery * 100).rounded())) %), VPKTAA periferia \(reconActive) \(Int(vpktaaPercent)) % "
                   + "nitidez \(vpktaaSharpness), MSAA \(gameMSAA) (en tile \(Self.msaaOnTile)), aniso x\(anisotropy), "
                   + "idioma \(lang.name) (\(lang.reason)), movimiento \(movement), subtítulos \(subtitles), FPS \(showFps), capturas \(diagCaptures), "
                   + "medir GPU \(gpuPassProfiling), cola GPU \(Self.gpuQueueDepth), orden por recursos \(trackedOrder), SSAO \(ssao), "
                   + "dedos por manos \(handFingers), amplificación de vértices \(amplify), post al área física \(postPhysical), ojos sin copia \(eyeDirect), altura \(Int(heightOffsetCm)) cm, oclusión medida \(occlusionQueries), Hz al juego \(reportedHz), arranque anticipado \(runningStart), test A/B \(abTest), motor \(engine.rawValue), preset \(preset.rawValue)")
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

    /// The fidelity table: one fixed level (scale 1.0: the render size is KLVR_EYE_SIZE). The old dynamic-resolution
    /// range (levels the game's auto-fidelity moved between) is gone: the eye size and the foveation map are fixed
    /// at launch, so the game rescaling its targets underneath them was never a safe setting.
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
        return header + row(0, true, 1.0) + "end,,,,,,,,,,,,,\n"
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
        klvr_plat_set_height_offset(Float(heightOffsetCm / 100))
        KleptonCompositor.skipSameEnabled = Self.composeNewOnly
        KleptonTAA.reloadSettings(percent: Float(vpktaaPercent), sharpness: Float(vpktaaSharpness))
        KleptonCompositor.setPeripheryRecon(on: reconActive, percent: Float(vpktaaPercent), sharpness: Float(vpktaaSharpness))
        // On/off needs a restart (the scene-pass hook is installed at start); the periphery is live.
        if foveationUsable {
            kl_vrr_set(2, -1, -1, Float(periphery))
            // The round sharp zone follows the map, at its live periphery (degrees stay the launch's).
            KleptonCompositor.setRoundFovea(on: Self.roundSharpZone, degrees: nil, edge: Float(periphery))
        }
        applyToVPKEngine()
        AVPLog.log("Ajustes en vivo: foveado \(foveationOn) periferia \(Int((periphery * 100).rounded())) %, VPKTAA periferia \(reconActive) \(Int(vpktaaPercent)) % nitidez \(vpktaaSharpness), FPS \(showFps)")
    }

    func applyToVPKEngine() {
        var c = avp_gfx_config()
        c.foveation_mode = foveationUsable ? 1 : 0   // 1 = the wide map (what the M2 preset was)
        c.sharp_zone = 0.18
        c.periphery = Float(periphery)
        c.transition = 0.32
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
