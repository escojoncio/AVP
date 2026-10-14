// AVP: the Settings screen. Every setting that rules over the game is here (never in a text
// file), plus the signing certificate, the AVP folder, the Steam account and the logs.

import SwiftUI
import UniformTypeIdentifiers

struct AVPSettingsView: View {
    @ObservedObject private var model = AVPModel.shared
    @ObservedObject private var s = AVPSettings.shared
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var p12: Data?
    @State private var password = ""
    @State private var result: String?
    @State private var pickingFolder = false
    @State private var pickingFoz = false
    @State private var fozResult: String?
    @State private var confirmQuarantine = false
    @State private var quarantined = AVPPipelineCache.quarantineCount()

    private func pct(_ v: Double) -> String { "\(Int((v * 100).rounded())) %" }

    var body: some View {
        NavigationStack {
            Form {
                picture
                foveationSection
                textures
                gameSection
                diagnostics
                certificateSection
                accountSection
                logsSection
            }
            .navigationTitle(AVPL("Ajustes", "Settings"))
            .toolbar { Button(AVPL("Hecho", "Done")) { dismiss() } }
            .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "p12") ?? .data, .data]) { r in
                if case .success(let url) = r {
                    let scoped = url.startAccessingSecurityScopedResource()
                    p12 = try? Data(contentsOf: url)
                    if scoped { url.stopAccessingSecurityScopedResource() }
                    result = p12 == nil ? AVPL("No se pudo leer el archivo.", "The file could not be read.") : nil
                }
            }
        }
    }

    // Build 32: one screen anyone can read. What a run showed to be the only sane value is no longer a setting
    // (AVPSettings: gpuQueueDepth, composeNewOnly, guestHz, roundSharpZone, msaaOnTile; dynamic resolution, the
    // texture pool, the M2/M5/custom foveation presets and the MoltenVK engine are gone).

    private var picture: some View {
        Section {
            let eye = s.eyeSize
            Stepper(AVPL("Resolución: \(Int(s.renderPercent)) % (\(eye.width)×\(eye.height) por ojo)",
                         "Resolution: \(Int(s.renderPercent)) % (\(eye.width)×\(eye.height) per eye)"),
                    value: $s.renderPercent, in: 50...130, step: 5)
            Toggle(AVPL("Mostrar FPS", "Show FPS"), isOn: $s.showFps)
        } header: {
            Text(AVPL("Imagen", "Picture"))
        } footer: {
            Text(AVPL("100 % = lo que pide el Vision Pro (3072×2464 por ojo). Menos resolución = más fluidez. El juego va a 50 fps cuando la GPU llega y a 33 cuando no; el visor siempre a 100 Hz. Al arrancar el juego.",
                      "100 % = what Vision Pro asks for (3072×2464 per eye). Lower resolution = smoother. The game runs at 50 fps when the GPU keeps up and 33 when it does not; the headset always at 100 Hz. At game start."))
        }
    }

    private var foveationSection: some View {
        Section {
            Toggle(AVPL("Foveado (centro nítido, bordes a menos resolución)", "Foveation (sharp centre, lower-resolution edges)"),
                   isOn: $s.foveationOn)
            if s.foveationOn {
                Stepper(AVPL("Zona nítida: \(Int(s.wideDegrees))°", "Sharp zone: \(Int(s.wideDegrees))°"),
                        value: $s.wideDegrees, in: 30...70, step: 5)
                Stepper(AVPL("Calidad de los bordes: \(pct(s.periphery))", "Edge quality: \(pct(s.periphery))"),
                        value: $s.periphery, in: AVPSettings.peripheryRange, step: 0.05)
                Toggle(AVPL("Suavizar los bordes (VPKTAA)", "Smooth the edges (VPKTAA)"), isOn: $s.vpktaa)
                if s.vpktaa {
                    Stepper(AVPL("Intensidad: \(Int(s.vpktaaPercent)) %", "Strength: \(Int(s.vpktaaPercent)) %"),
                            value: $s.vpktaaPercent, in: 0...100, step: 5)
                    Stepper(AVPL("Nitidez: \(pct(s.vpktaaSharpness))", "Sharpness: \(pct(s.vpktaaSharpness))"),
                            value: $s.vpktaaSharpness, in: 0...1, step: 0.05)
                }
            }
        } header: {
            Text(AVPL("Foveado", "Foveation"))
        } footer: {
            Text(s.foveationOn
                 ? AVPL("Zona nítida redonda (como en P.T.) a resolución completa, 10° por debajo de la mirada; fuera de ella los bordes se dibujan a la calidad elegida (10 % = máximo rendimiento; 65 % para un M5). La zona nítida y el foveado sí/no se aplican al arrancar; la calidad de los bordes y el suavizado, en vivo desde la pausa. El juego siempre usa MSAA 4x.",
                        "Round sharp zone (as in P.T.) at full resolution, 10° below the gaze; outside it the edges are drawn at the chosen quality (10 % = most performance; 65 % for an M5). The sharp zone and foveation on/off apply at game start; edge quality and smoothing live from the pause menu. The game always uses 4x MSAA.")
                 : AVPL("Sin foveado toda la imagen se dibuja a resolución completa: mucho más lento. Al arrancar el juego.",
                        "Without foveation the whole picture is drawn at full resolution: much slower. At game start."))
        }
    }

    private var textures: some View {
        Section {
            Picker(AVPL("Tamaño máximo de textura", "Maximum texture size"), selection: $s.textureCap) {
                Text("1024").tag(1024)
                Text("2048").tag(2048)
                Text("4096").tag(4096)
            }
            .pickerStyle(.segmented)
            Picker(AVPL("Filtrado anisotrópico", "Anisotropic filtering"), selection: $s.anisotropy) {
                Text("Off").tag(0); Text("x2").tag(2); Text("x4").tag(4); Text("x8").tag(8); Text("x16").tag(16)
            }
            .pickerStyle(.segmented)
            Toggle(AVPL("Oclusión ambiental (SSAO)", "Ambient occlusion (SSAO)"), isOn: $s.ssao)
        } header: {
            Text(AVPL("Texturas y efectos", "Textures and effects"))
        } footer: {
            Text(s.textureCap == 4096
                 ? AVPL("4096 necesita más memoria de la que tiene el visor (~3,3 GB): puede haber texturas que aparecen tarde. 2048 es lo probado. Al arrancar el juego.",
                        "4096 needs more memory than the headset has (~3.3 GB): textures may pop in late. 2048 is the tested value. At game start.")
                 : AVPL("2048 es lo probado. Al arrancar el juego.", "2048 is the tested value. At game start."))
        }
    }

    private var gameSection: some View {
        Section {
            Toggle(AVPL("Idioma del sistema si el juego lo tiene (si no, inglés)", "System language if the game has it (else English)"),
                   isOn: $s.systemLanguage)
            Picker(AVPL("Movimiento (jugador nuevo)", "Movement (new player)"), selection: $s.movement) {
                Text(AVPL("Teletransporte", "Teleport")).tag(AVPSettings.Movement.teleport)
                Text(AVPL("Continuo (cabeza)", "Continuous (head)")).tag(AVPSettings.Movement.continuousHead)
                Text(AVPL("Continuo (mano)", "Continuous (hand)")).tag(AVPSettings.Movement.continuousHand)
            }
            Picker(AVPL("Subtítulos", "Subtitles"), selection: $s.subtitles) {
                Text(AVPL("Como el juego (abajo)", "As the game (bottom)")).tag(AVPSettings.SubtitlePlacement.game)
                Text(AVPL("Más arriba", "Higher")).tag(AVPSettings.SubtitlePlacement.higher)
                Text(AVPL("A la altura de la vista", "At eye level")).tag(AVPSettings.SubtitlePlacement.eyeLevel)
                Text(AVPL("Por encima de la vista", "Above eye level")).tag(AVPSettings.SubtitlePlacement.high)
            }
            Picker(AVPL("Tamaño de subtítulos", "Subtitle size"), selection: $s.subtitleSize) {
                Text(AVPL("Pequeño", "Small")).tag(AVPSettings.SubtitleSize.small)
                Text(AVPL("Medio", "Medium")).tag(AVPSettings.SubtitleSize.medium)
                Text(AVPL("Grande", "Large")).tag(AVPSettings.SubtitleSize.large)
            }
            Stepper(AVPL("Altura del jugador: \(Int(s.heightOffsetCm)) cm", "Player height: \(Int(s.heightOffsetCm)) cm"),
                    value: $s.heightOffsetCm, in: -60...30, step: 5)
            Toggle(AVPL("Sincronizar partidas con Steam Cloud", "Sync saves with Steam Cloud"), isOn: $s.cloudSync)
            Toggle(AVPL("Dedos reales (seguimiento de manos del visor)", "Real fingers (the headset's hand tracking)"), isOn: $s.handFingers)
        } header: {
            Text(AVPL("Juego", "Game"))
        } footer: {
            Text(AVPL("Las voces siempre en inglés. El movimiento solo se aplica mientras el juego no tenga opciones guardadas. Subtítulos: el juego los pone abajo; las otras opciones los suben. Altura del jugador: negativo = Alyx más baja (jugando sentado, o si el suelo del juego queda demasiado lejos de las manos); se aplica en vivo desde la pausa. Dedos reales: los dedos del jugador siguen a tus dedos de verdad (como con los mandos Index de Valve) cuando el visor ve la mano; pide permiso de seguimiento de manos la primera vez. Con un mando Sense en la mano el visor NO da el seguimiento de esa mano (medido): solo actúa con las manos libres. Al arrancar el juego.",
                      "Voices are always English. Movement only applies until the game has saved options. Subtitles: the game puts them low; the other options raise them. Player height: negative = Alyx lower (playing seated, or when the game's floor sits too far from your hands); applies live from the pause menu. Real fingers: the player's fingers follow your own (as with Valve's Index controllers) when the headset sees the hand; asks for the hand-tracking permission once. With a Sense controller in the hand the headset does NOT track that hand (measured): it only acts with free hands. At game start."))
        }
    }

    private var diagnostics: some View {
        Section {
            Toggle(AVPL("Capturas de diagnóstico", "Diagnostic captures"), isOn: $s.diagCaptures)
            Toggle(AVPL("Medir el tiempo de GPU por pase", "Per-pass GPU timing"), isOn: $s.gpuPassProfiling)
            Toggle(AVPL("Orden de GPU por recursos", "GPU ordering by resources"), isOn: $s.trackedOrder)
            Toggle(AVPL("Amplificación de vértices", "Vertex amplification"), isOn: $s.amplify)
            Toggle(AVPL("Post-procesado solo en el área foveada (prueba)", "Post-processing on the foveated area only (test)"), isOn: $s.postPhysical)
            Toggle(AVPL("Ojos al compositor sin copia", "Eyes to the compositor without a copy"), isOn: $s.eyeDirect)
            Toggle(AVPL("Occlusion culling medido (consultas de GPU)", "Measured occlusion culling (GPU queries)"), isOn: $s.occlusionQueries)
            Toggle(AVPL("Arranque anticipado del frame (CPU en paralelo con la GPU)", "Running start (CPU in parallel with the GPU)"), isOn: $s.runningStart)
            VStack(alignment: .leading, spacing: 4) {
                Toggle(AVPL("Test automático de rendimiento", "Automatic performance test"), isOn: $s.abTest)
                Text(AVPL("Unos 2 minutos tras cargar, quieto en el menú; el HUD avisa cuando termina. Solo deja activo lo que mejora.",
                          "About 2 minutes after loading, standing still in the menu; the HUD says when it is done. Only what helps stays on."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Picker(AVPL("Frecuencia que se le dice al juego", "Refresh rate told to the game"), selection: $s.reportedHz) {
                Text(AVPL("Automática (ritmo real)", "Automatic (the real pace)")).tag(AVPSettings.ReportedHz.measured)
                Text(AVPL("Fija 50 Hz", "Fixed 50 Hz")).tag(AVPSettings.ReportedHz.fixed50)
                Text(AVPL("Fija 90 Hz", "Fixed 90 Hz")).tag(AVPSettings.ReportedHz.fixed90)
            }
            Button(AVPL("Restablecer shaders en cuarentena (\(quarantined))", "Reset quarantined shaders (\(quarantined))"),
                   role: .destructive) { confirmQuarantine = true }
                .disabled(quarantined == 0)
                .confirmationDialog(AVPL("¿Restablecer los \(quarantined) pipelines en cuarentena?",
                                         "Reset the \(quarantined) quarantined pipelines?"),
                                    isPresented: $confirmQuarantine, titleVisibility: .visible) {
                    Button(AVPL("Restablecer", "Reset"), role: .destructive) {
                        AVPPipelineCache.resetQuarantine()
                        quarantined = AVPPipelineCache.quarantineCount()
                    }
                    Button(AVPL("Cancelar", "Cancel"), role: .cancel) {}
                } message: {
                    Text(AVPL("VPKEngine volverá a dibujarlos en el próximo arranque. Si alguno vuelve a colgar la GPU, "
                              + "entrará otra vez en cuarentena.",
                              "VPKEngine draws them again at the next launch. One that hangs the GPU again goes back into quarantine."))
                }
                .onAppear { quarantined = AVPPipelineCache.quarantineCount() }
            Button(AVPL("Restablecer todos los ajustes", "Reset all settings"), role: .destructive) { s.resetToDefaults() }
        } header: {
            Text(AVPL("Diagnóstico (solo si te lo piden)", "Diagnostics (only when asked)"))
        } footer: {
            Text(AVPL("Déjalo como está salvo que se te pida para un registro. Capturas: imágenes de los ojos y un volcado pase a pase en Logs Alyx; con ellas activas, L3 + R3 a la vez guarda el fallo que estés viendo. Medir GPU: escribe los tiempos en el registro, cuesta algo de rendimiento. Orden por recursos: menos esperas en la GPU; si ves geometría que explota, apágalo. Amplificación de vértices: los dos ojos en una sola pasada de geometría (menos tiempo de GPU); si ves algo raro en un ojo, apágalo. Todo al arrancar el juego. Arranque anticipado: el juego prepara el siguiente frame mientras la GPU acaba el actual (apagado = como antes, la GPU espera ~5 ms en cada frame). Frecuencia al juego: Alyx avanza su reloj y fija su tick con este número. Automática = el ritmo real (50, o 33 en zonas densas; 50 durante las cargas). Las fijas son solo para pruebas: 90 va a cámara lenta (requiere reiniciar el juego).",
                      "Leave it as it is unless asked for a log. Captures: eye pictures and a pass-by-pass dump in Logs Alyx; with them on, L3 + R3 together saves the glitch you are seeing. GPU timing: writes the timings to the log, costs some performance. Ordering by resources: fewer GPU waits; if geometry explodes, turn it off. Vertex amplification: both eyes in one geometry pass (less GPU time); if one eye looks wrong, turn it off. All at game start. Running start: the game builds the next frame while the GPU finishes the current one (off = as before, the GPU waits ~5 ms every frame). Refresh rate told to the game: Alyx steps its clock and fixes its tick from this number. Automatic = the real pace (50, or 33 in dense areas; 50 during loads). The fixed ones are tests only: 90 runs in slow motion (game restart)."))
        }
    }

    private var certificateSection: some View {
        Section(AVPL("Certificado de firma", "Signing certificate")) {
            Text(model.certificate ?? AVPL("Ninguno", "None")).foregroundStyle(.secondary)
            Text(AVPL("El .p12 con el que se firmó la app. Las librerías convertidas se firman con él en el visor; si cambia, se vuelven a firmar todas.",
                      "The .p12 the app was signed with. Converted libraries are signed with it on the headset; if it changes, they are all signed again."))
                .font(.caption)
            Button(AVPL("Importar .p12…", "Import .p12…")) { importing = true }
            if let data = p12 {
                SecureField(AVPL("Contraseña", "Password"), text: $password)
                Button(AVPL("Guardar certificado", "Save certificate")) {
                    do {
                        result = try AVPSigner.store(p12: data, password: password)
                        model.refreshCertificate()
                        p12 = nil; password = ""
                    } catch { result = error.localizedDescription }
                }
            }
            if model.certificate != nil {
                Button(AVPL("Borrar certificado", "Remove certificate"), role: .destructive) {
                    AVPSigner.remove(); model.refreshCertificate()
                }
            }
            if let result { Text(result).font(.caption) }
        }
    }

    private var accountSection: some View {
        Section(AVPL("Cuenta y carpeta", "Account and folder")) {
            if !model.accountName.isEmpty {
                LabeledContent("Steam", value: model.accountName)
                Button(AVPL("Cerrar sesión", "Sign out"), role: .destructive) { model.signOut() }
            }
            Text(model.folderPath ?? AVPL("Carpeta AVP no elegida", "AVP folder not chosen")).font(.caption)
            Button(AVPL("Elegir carpeta AVP…", "Choose AVP folder…")) { pickingFolder = true }
                // On the button, not the Form: two .fileImporter on one view and only one works.
                .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { r in
                    if case .success(let url) = r { model.choose(url) }
                }
            // Build 41: a Fossilize pipeline database (e.g. the PC's steamapps/shadercache/546560/fozpipelinesv6/
            // steamapp_pipeline_cache.foz) copied to the AVP folder's root, where the next preparation precompiles it
            // (AVPPrepare.importExtraFoz).
            Button(AVPL("Importar caché de shaders (.foz)…", "Import shader cache (.foz)…")) { pickingFoz = true }
                .disabled(model.folderPath == nil)
                .fileImporter(isPresented: $pickingFoz, allowedContentTypes: [.data, .item]) { r in
                    guard case .success(let src) = r else { return }
                    fozResult = AVPL("Copiando…", "Copying…")
                    Task.detached {   // ~64 MB: off the main thread
                        let msg = Self.importFoz(src)
                        await MainActor.run { fozResult = msg }
                    }
                }
            if let fozResult { Text(fozResult).font(.caption) }
        }
    }

    /// Copies the chosen file to the AVP folder's root as <name>.foz. The file must be a Fossilize database (its
    /// 16-byte magic); anything else is refused, so a wrong pick cannot reach the replay.
    static func importFoz(_ src: URL) -> String {
        let scoped = src.startAccessingSecurityScopedResource()
        defer { if scoped { src.stopAccessingSecurityScopedResource() } }
        guard let root = AVPFolder.shared.cache?.deletingLastPathComponent() else {
            return AVPL("Elige antes la carpeta AVP.", "Choose the AVP folder first.")
        }
        guard let h = try? FileHandle(forReadingFrom: src), let head = try? h.read(upToCount: 12),
              head.count == 12, head.dropFirst().starts(with: Array("FOSSILIZEDB".utf8)) else {
            return AVPL("Ese fichero no es una caché de pipelines (.foz de Fossilize).",
                        "That file is not a pipeline cache (Fossilize .foz).")
        }
        try? h.close()
        var name = src.deletingPathExtension().lastPathComponent
        if name.isEmpty { name = "shadercache" }
        let dst = root.appendingPathComponent(name + ".foz")
        let fm = FileManager.default
        func real(_ u: URL) -> String { u.standardizedFileURL.resolvingSymlinksInPath().path }
        if real(src) == real(dst) {   // already in place (picked from the AVP folder itself): nothing to copy
            AVPLog.log("Ajustes: caché de shaders ya en la carpeta AVP: \(dst.lastPathComponent)")
            return AVPL("Ya estaba en la carpeta AVP: se precompila en la próxima preparación.",
                        "Already in the AVP folder: it is precompiled at the next preparation.")
        }
        do {
            let tmp = root.appendingPathComponent(".import-" + name + ".tmp")   // not *.foz: never picked up half-copied
            try? fm.removeItem(at: tmp)
            try fm.copyItem(at: src, to: tmp)
            if fm.fileExists(atPath: dst.path) { _ = try fm.replaceItemAt(dst, withItemAt: tmp) }
            else { try fm.moveItem(at: tmp, to: dst) }
            let mb = ((try? fm.attributesOfItem(atPath: dst.path)[.size] as? NSNumber)?.int64Value ?? 0) / 1_048_576
            AVPLog.log("Ajustes: caché de shaders importada: \(dst.lastPathComponent) (\(mb) MB)")
            return AVPL("Importada (\(mb) MB). Se precompila en la próxima preparación (una vez, unos minutos).",
                        "Imported (\(mb) MB). It is precompiled at the next preparation (once, a few minutes).")
        } catch {
            return AVPL("No se pudo copiar: ", "Could not copy: ") + error.localizedDescription
        }
    }

    private var logsSection: some View {
        Section(AVPL("Registros", "Logs")) {
            ShareLink(items: AVPLog.shareable) { Label(AVPL("Compartir registros", "Share logs"), systemImage: "square.and.arrow.up") }
            ScrollView {
                Text(AVPLog.tail(AVPLog.appLog)).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 220)
        }
    }
}
