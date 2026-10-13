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

    private func pct(_ v: Double) -> String { "\(Int((v * 100).rounded())) %" }

    var body: some View {
        NavigationStack {
            Form {
                resolution
                textures
                antialiasing
                foveationSection
                display
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

    private var resolution: some View {
        Section {
            let eye = s.eyeSize
            Stepper(AVPL("Resolución: \(Int(s.renderPercent)) % de la nativa (\(eye.width)×\(eye.height) por ojo)",
                         "Resolution: \(Int(s.renderPercent)) % of native (\(eye.width)×\(eye.height) per eye)"),
                    value: $s.renderPercent, in: 50...130, step: 5)
            Toggle(AVPL("Resolución dinámica", "Dynamic resolution"), isOn: $s.dynamicResolution)
            if s.dynamicResolution {
                Stepper(AVPL("Mínimo: \(pct(s.dynamicMin))", "Minimum: \(pct(s.dynamicMin))"), value: $s.dynamicMin, in: 0.5...1.0, step: 0.05)
                Stepper(AVPL("Máximo: \(pct(s.dynamicMax))", "Maximum: \(pct(s.dynamicMax))"), value: $s.dynamicMax, in: 0.6...1.2, step: 0.05)
            }
        } header: {
            Text(AVPL("Resolución", "Resolution"))
        } footer: {
            Text(AVPL("Nativa = lo que pide el Vision Pro (3072×2464 por ojo). 90 % es la configuración probada. Con resolución dinámica el juego baja la escala cuando no llega a tiempo.",
                      "Native = what Vision Pro asks for (3072×2464 per eye). 90 % is the tested setting. With dynamic resolution the game lowers the scale when it runs late."))
        }
    }

    private var textures: some View {
        Section(AVPL("Texturas", "Textures")) {
            Stepper(AVPL("Memoria de texturas: \(s.texturePoolMB) MB", "Texture memory: \(s.texturePoolMB) MB"),
                    value: $s.texturePoolMB, in: 1536...2816, step: 128)
            Picker(AVPL("Tamaño máximo", "Maximum size"), selection: $s.textureCap) {
                Text("1024").tag(1024)
                Text("2048").tag(2048)
                Text("4096").tag(4096)
            }
            .pickerStyle(.segmented)
            Picker(AVPL("Filtrado anisotrópico", "Anisotropic filtering"), selection: $s.anisotropy) {
                Text("Off").tag(0); Text("x2").tag(2); Text("x4").tag(4); Text("x8").tag(8); Text("x16").tag(16)
            }
            .pickerStyle(.segmented)
            if s.textureCap == 4096 {
                Text(AVPL("4096 necesita más memoria de la que tiene el visor (~3,3 GB): puede haber texturas que aparecen tarde.",
                          "4096 needs more memory than the headset has (~3.3 GB): textures may pop in late."))
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var antialiasing: some View {
        Section {
            Toggle("VPKTAA", isOn: $s.vpktaa)
            if s.vpktaa {
                Stepper(AVPL("Intensidad: \(Int(s.vpktaaPercent)) %", "Strength: \(Int(s.vpktaaPercent)) %"),
                        value: $s.vpktaaPercent, in: 0...100, step: 5)
                Stepper(AVPL("Nitidez: \(pct(s.vpktaaSharpness))", "Sharpness: \(pct(s.vpktaaSharpness))"),
                        value: $s.vpktaaSharpness, in: 0...1, step: 0.05)
            }
        } header: {
            Text(AVPL("Antialiasing", "Antialiasing"))
        } footer: {
            Text(s.vpktaa ? AVPL("El MSAA del juego queda apagado: VPKTAA hace el antialiasing.", "The game's MSAA stays off: VPKTAA does the antialiasing.")
                          : AVPL("Sin VPKTAA el juego usa MSAA 4x.", "Without VPKTAA the game uses 4x MSAA."))
        }
    }

    private var foveationSection: some View {
        Section(AVPL("Foveado", "Foveation")) {
            Picker(AVPL("Foveado", "Foveation"), selection: $s.foveation) {
                Text(AVPL("Apagado", "Off")).tag(AVPSettings.Foveation.off)
                Text("M2").tag(AVPSettings.Foveation.m2)
                if AVPSettings.isM5 { Text("M5").tag(AVPSettings.Foveation.m5) }
                Text(AVPL("Personalizado", "Custom")).tag(AVPSettings.Foveation.custom)
            }
            .pickerStyle(.segmented)
            if s.foveation == .custom {
                Stepper(AVPL("Zona nítida: \(pct(s.sharpZone))", "Sharp zone: \(pct(s.sharpZone))"), value: $s.sharpZone, in: 0.05...0.6, step: 0.01)
                Stepper(AVPL("Periferia: \(pct(s.periphery))", "Periphery: \(pct(s.periphery))"), value: $s.periphery, in: 0.1...1, step: 0.05)
                Stepper(AVPL("Transición: \(pct(s.transition))", "Transition: \(pct(s.transition))"), value: $s.transition, in: 0.02...0.5, step: 0.02)
            }
        }
    }

    private var display: some View {
        Section(AVPL("Pantalla", "Display")) {
            Picker(AVPL("Frecuencia", "Refresh rate"), selection: $s.refreshHz) {
                Text("90 Hz").tag(90)
                Text("100 Hz").tag(100)
            }
            .pickerStyle(.segmented)
            Toggle(AVPL("El juego dibuja a la mitad (\(s.refreshHz / 2) fps, más estable)", "Game renders at half rate (\(s.refreshHz / 2) fps, steadier)"),
                   isOn: $s.halfRate)
            Toggle(AVPL("Mostrar FPS", "Show FPS"), isOn: $s.showFps)
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
            Toggle(AVPL("Sincronizar partidas con Steam Cloud", "Sync saves with Steam Cloud"), isOn: $s.cloudSync)
        } header: {
            Text(AVPL("Juego", "Game"))
        } footer: {
            Text(AVPL("Las voces siempre en inglés. El movimiento solo se aplica mientras el juego no tenga opciones guardadas.",
                      "Voices are always English. Movement only applies until the game has saved options."))
        }
    }

    private var diagnostics: some View {
        Section {
            Picker(AVPL("Motor gráfico", "Graphics engine"), selection: $s.engine) {
                Text("VPEngine").tag(AVPSettings.Engine.vpengine)
                Text(AVPL("MoltenVK (diagnóstico)", "MoltenVK (diagnostic)")).tag(AVPSettings.Engine.moltenvk)
            }
            Toggle(AVPL("Capturas de diagnóstico", "Diagnostic captures"), isOn: $s.diagCaptures)
            Button(AVPL("Restablecer ajustes", "Reset settings"), role: .destructive) { s.resetToDefaults() }
        } header: {
            Text(AVPL("Diagnóstico", "Diagnostics"))
        } footer: {
            Text(AVPL("Todo se aplica al lanzar el juego, por encima de lo que diga el juego o Steam Cloud.",
                      "Everything is applied when the game launches, over whatever the game or Steam Cloud says."))
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
