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
    @State private var diagnosticsOpen = false

    private func pct(_ v: Double) -> String { "\(Int((v * 100).rounded())) %" }

    var body: some View {
        NavigationStack {
            Form {
                picture
                performance
                gameSection
                resetSection
                certificateSection
                accountSection
                logsSection
                diagnostics
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
    // (AVPSettings: gpuQueueDepth, composeNewOnly, roundSharpZone, msaaOnTile; dynamic resolution, the
    // texture pool are gone). Build 53: picture presets M2/M5/Personalizado.
    // Every option carries its own grey help line (hint): what it does, when to touch it, the recommended value.

    /// The grey help line under an option.
    private func hint(_ es: String, _ en: String) -> some View {
        Text(AVPL(es, en))
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    private var picture: some View {
        Section {
            let eye = s.eyeSize
            VStack(alignment: .leading, spacing: 6) {
                Text(AVPL("Preset", "Preset"))
                Picker(AVPL("Preset", "Preset"), selection: $s.preset) {
                    Text("M2").tag(AVPSettings.Preset.m2)
                    Text("M5").tag(AVPSettings.Preset.m5)
                    Text(AVPL("Personalizado", "Custom")).tag(AVPSettings.Preset.custom)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                hint("Conjunto de ajustes de imagen recomendado. M5 usa por ahora los mismos valores que M2 (sin medir en un M5). Tócalo solo si quieres volver a los valores buenos tras experimentar. Si cambias a mano un ajuste de imagen (no Fotogramas, Mostrar FPS ni Nitidez del centro), pasa a Personalizado. Recomendado: el que corresponde a tu visor (M2 o M5). Se aplica al arrancar el juego.",
                     "Recommended set of picture settings. M5 uses the same values as M2 for now (not measured on an M5). Touch it only to go back to the good values after experimenting. If you change a picture setting by hand (not Frame rate, Show FPS or Centre sharpness), it switches to Custom. Recommended: the one for your headset (M2 or M5). Applied at game start.")
            }
            VStack(alignment: .leading, spacing: 4) {
                Stepper(AVPL("Resolución: \(Int(s.renderPercent)) % (\(eye.width)×\(eye.height) por ojo)",
                             "Resolution: \(Int(s.renderPercent)) % (\(eye.width)×\(eye.height) per eye)"),
                        value: $s.renderPercent, in: 50...130, step: 5)
                hint("Cuántos píxeles dibuja el juego en cada ojo; 100 % es lo que pide el Vision Pro (3072×2464 por ojo). Más = más nítido pero más pesado. Bájala si ves tirones; súbela si te sobra rendimiento. Recomendado: 70 % (lo que ponen los presets). Se aplica al arrancar el juego.",
                     "How many pixels the game draws in each eye; 100 % is what Vision Pro asks for (3072×2464 per eye). More = sharper but heavier. Lower it if you see hitches; raise it if you have performance to spare. Recommended: 70 % (what the presets set). Applied at game start.")
            }
            VStack(alignment: .leading, spacing: 4) {
                Stepper(AVPL("Nitidez del centro: \(pct(s.centerSharpness))", "Centre sharpness: \(pct(s.centerSharpness))"),
                        value: $s.centerSharpness, in: 0...1, step: 0.05)
                hint("Afila la imagen solo en la zona nítida del centro, sin halos; los bordes no se afilan. Súbela si la imagen se ve algo blanda; bájala si ves demasiado contraste. 0 % lo desactiva. Recomendado: 50 %. Se aplica en vivo.",
                     "Sharpens the picture only in the sharp centre zone, without halos; the edges are not sharpened. Raise it if the picture looks soft; lower it if you see too much contrast. 0 % turns it off. Recommended: 50 %. Applied live.")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(AVPL("Antialiasing (MSAA)", "Antialiasing (MSAA)"))
                Picker(AVPL("Antialiasing (MSAA)", "Antialiasing (MSAA)"), selection: $s.msaa) {
                    Text("Off").tag(0); Text("x2").tag(2); Text("x4").tag(4)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                hint("Suaviza los bordes dentados de los objetos. x4 se ve más suave; x2 es más ligero. Recomendado: x4. Se aplica al arrancar el juego.",
                     "Smooths the jagged edges of objects. x4 looks smoother; x2 is lighter. Recommended: x4. Applied at game start.")
            }
            if s.msaa == 0 {
                Text(AVPL("Sin MSAA no se aplica el foveado.", "Without MSAA foveation is not applied."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Toggle(AVPL("Oclusión ambiental (SSAO)", "Ambient occlusion (SSAO)"), isOn: $s.ssao)
                hint("Añade sombras suaves en esquinas y juntas, lo que da más sensación de volumen. Cuesta algo de GPU. Recomendado: activada; apágala solo si necesitas más rendimiento. Se aplica al arrancar el juego.",
                     "Adds soft shadows in corners and joints, giving more sense of volume. Costs some GPU. Recommended: on; turn it off only if you need more performance. Applied at game start.")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(AVPL("Filtrado anisotrópico", "Anisotropic filtering"))
                Picker(AVPL("Filtrado anisotrópico", "Anisotropic filtering"), selection: $s.anisotropy) {
                    Text("Off").tag(0); Text("x2").tag(2); Text("x4").tag(4); Text("x8").tag(8); Text("x16").tag(16)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                hint("Mantiene nítidas las texturas que ves de lado (suelos, paredes). Cuesta poco rendimiento. Recomendado: x16. Se aplica al arrancar el juego.",
                     "Keeps textures seen at an angle (floors, walls) sharp. Costs little performance. Recommended: x16. Applied at game start.")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(AVPL("Tamaño máximo de textura", "Maximum texture size"))
                Picker(AVPL("Tamaño máximo de textura", "Maximum texture size"), selection: $s.textureCap) {
                    Text("1024").tag(1024)
                    Text("2048").tag(2048)
                    Text("4096").tag(4096)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                hint("Límite de resolución de las texturas del juego: más grande = más detalle pero mucha más memoria. Recomendado: 2048 (lo probado). Se aplica al arrancar el juego.",
                     "Resolution limit of the game's textures: larger = more detail but much more memory. Recommended: 2048 (the tested value). Applied at game start.")
                if s.textureCap == 4096 {
                    hint("4096 necesita más memoria de la que tiene el visor (~3,3 GB): puede haber texturas que aparecen tarde.",
                         "4096 needs more memory than the headset has (~3.3 GB): textures may pop in late.")
                }
            }
        } header: {
            Text(AVPL("Imagen", "Picture"))
        }
    }

    private var performance: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(AVPL("Fotogramas (al arrancar el juego)", "Frame rate (at game start)"))
                Picker(AVPL("Fotogramas (al arrancar el juego)", "Frame rate (at game start)"), selection: $s.frameRate) {
                    Text("Auto").tag(AVPSettings.FrameRate.auto)
                    Text(AVPL("45/50 fps", "45/50 fps")).tag(AVPSettings.FrameRate.high)
                    Text(AVPL("30/33 fps", "30/33 fps")).tag(AVPSettings.FrameRate.steady)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                hint("Cuántas imágenes nuevas hace el juego por segundo; el visor siempre muestra 90 Hz (100 Hz con luz artificial) y ajusta cada imagen a tu cabeza. Auto: 45/50 cuando la GPU llega y 30/33 cuando no. 45/50: siempre alto (más fluido, algún tirón). 30/33: siempre estable. Recomendado: Auto. Se aplica al arrancar el juego.",
                     "How many new pictures the game makes per second; the headset always shows 90 Hz (100 Hz under artificial light) and adjusts each picture to your head. Auto: 45/50 when the GPU keeps up, else 30/33. 45/50: always high (smoother, some hitches). 30/33: always steady. Recommended: Auto. Applied at game start.")
            }
            VStack(alignment: .leading, spacing: 4) {
                Toggle(AVPL("Mostrar FPS", "Show FPS"), isOn: $s.showFps)
                hint("Muestra un contador de fotogramas por segundo. Actívalo para comprobar el efecto de cambiar la resolución o el foveado. Recomendado: desactivado.",
                     "Shows a frames-per-second counter. Turn it on to check the effect of changing resolution or foveation. Recommended: off.")
            }
            VStack(alignment: .leading, spacing: 4) {
                Toggle(AVPL("Foveado (centro nítido, bordes a menos resolución)", "Foveation (sharp centre, lower-resolution edges)"),
                       isOn: $s.foveationOn)
                hint("Dibuja a resolución completa solo el centro, donde miras, y los bordes con menos: ahorra unos 3–7 ms por imagen (de ~23 en zonas pesadas). Sin foveado toda la imagen se dibuja a resolución completa. Recomendado: activado. Se aplica al arrancar el juego.",
                     "Draws only the centre, where you look, at full resolution and the edges at less: saves about 3–7 ms per frame (out of ~23 in heavy areas). Without foveation the whole picture is drawn at full resolution. Recommended: on. Applied at game start.")
            }
            if s.foveationOn {
                VStack(alignment: .leading, spacing: 4) {
                    Stepper(AVPL("Zona nítida: \(Int(s.wideDegrees))°", "Sharp zone: \(Int(s.wideDegrees))°"),
                            value: $s.wideDegrees, in: 30...70, step: 5)
                    hint("Anchura de la zona central redonda a resolución completa (algo por debajo de la mirada). Más grande = más nítido pero más lento. Recomendado: 70° (lo que ponen los presets). Se aplica al arrancar el juego.",
                         "Width of the round central zone at full resolution (a little below the gaze). Larger = sharper but slower. Recommended: 70° (what the presets set). Applied at game start.")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Stepper(AVPL("Calidad de los bordes: \(pct(s.periphery))", "Edge quality: \(pct(s.periphery))"),
                            value: $s.periphery, in: AVPSettings.peripheryRange, step: 0.05)
                    hint("Resolución a la que se dibujan los bordes. 10 % es lo más rápido; sube hasta 65 % si notas los bordes borrosos y te sobra rendimiento (sobre todo en un M5). Recomendado: 10 %. Se aplica en vivo desde la pausa.",
                         "Resolution the edges are drawn at. 10 % is the fastest; raise it up to 65 % if the edges look blurry and you have performance to spare (mostly on an M5). Recommended: 10 %. Applied live from the pause menu.")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(AVPL("Suavizar los bordes (VPKTAA)", "Smooth the edges (VPKTAA)"), isOn: $s.vpktaa)
                    hint("Reconstruye y suaviza los bordes que se dibujan a menos resolución para que no se vean pixelados. Recomendado: activado. Se aplica en vivo desde la pausa.",
                         "Reconstructs and smooths the edges drawn at lower resolution so they do not look pixelated. Recommended: on. Applied live from the pause menu.")
                }
                if s.vpktaa {
                    VStack(alignment: .leading, spacing: 4) {
                        Stepper(AVPL("Intensidad: \(Int(s.vpktaaPercent)) %", "Strength: \(Int(s.vpktaaPercent)) %"),
                                value: $s.vpktaaPercent, in: 0...100, step: 5)
                        hint("Cuánto suavizado se aplica a los bordes. Recomendado: 100 %.",
                             "How much smoothing is applied to the edges. Recommended: 100 %.")
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Stepper(AVPL("Nitidez: \(pct(s.vpktaaSharpness))", "Sharpness: \(pct(s.vpktaaSharpness))"),
                                value: $s.vpktaaSharpness, in: 0...1, step: 0.05)
                        hint("Cuánta definición conserva el suavizado de los bordes: más = más nítido, menos = más suave. Recomendado: 100 %.",
                             "How much definition the edge smoothing keeps: more = sharper, less = softer. Recommended: 100 %.")
                    }
                }
            }
        } header: {
            Text(AVPL("Rendimiento", "Performance"))
        }
    }

    private var gameSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Toggle(AVPL("Idioma del sistema si el juego lo tiene (si no, inglés)", "System language if the game has it (else English)"),
                       isOn: $s.systemLanguage)
                hint("Pone el juego en el idioma de tu visor si el juego lo tiene; si no, en inglés. Las voces siempre están en inglés. Recomendado: activado. Se aplica al arrancar el juego.",
                     "Puts the game in your headset's language if the game has it; otherwise English. Voices are always English. Recommended: on. Applied at game start.")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(AVPL("Movimiento (jugador nuevo)", "Movement (new player)"))
                Picker(AVPL("Movimiento (jugador nuevo)", "Movement (new player)"), selection: $s.movement) {
                    Text(AVPL("Teletransporte", "Teleport")).tag(AVPSettings.Movement.teleport)
                    Text(AVPL("Cabeza", "Head")).tag(AVPSettings.Movement.continuousHead)
                    Text(AVPL("Mano", "Hand")).tag(AVPSettings.Movement.continuousHand)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                hint("Cómo te desplazas. Teletransporte: saltas al punto que señalas (el más cómodo si te mareas). Cabeza: avanzas hacia donde miras. Mano: avanzas hacia donde apunta el mando. Solo se aplica mientras el juego no tenga opciones guardadas; después se cambia dentro del juego. Recomendado: Mano.",
                     "How you move. Teleport: you jump to the point you aim at (the most comfortable if you get motion sick). Head: you move where you look. Hand: you move where the controller points. It only applies until the game has saved options; after that, change it inside the game. Recommended: Hand.")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(AVPL("Subtítulos", "Subtitles"))
                Picker(AVPL("Subtítulos", "Subtitles"), selection: $s.subtitles) {
                    Text(AVPL("Abajo", "Bottom")).tag(AVPSettings.SubtitlePlacement.game)
                    Text(AVPL("Más arriba", "Higher")).tag(AVPSettings.SubtitlePlacement.higher)
                    Text(AVPL("A la vista", "Eye level")).tag(AVPSettings.SubtitlePlacement.eyeLevel)
                    Text(AVPL("Encima", "Above")).tag(AVPSettings.SubtitlePlacement.high)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                hint("Dónde se ven los subtítulos. Abajo: donde los pone el juego; las otras opciones los suben. Cámbialo si te cuesta leerlos. Recomendado: A la vista. Se aplica al arrancar el juego.",
                     "Where the subtitles appear. Bottom: where the game puts them; the other options raise them. Change it if they are hard to read. Recommended: Eye level. Applied at game start.")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(AVPL("Tamaño de subtítulos", "Subtitle size"))
                Picker(AVPL("Tamaño de subtítulos", "Subtitle size"), selection: $s.subtitleSize) {
                    Text(AVPL("Pequeño", "Small")).tag(AVPSettings.SubtitleSize.small)
                    Text(AVPL("Medio", "Medium")).tag(AVPSettings.SubtitleSize.medium)
                    Text(AVPL("Grande", "Large")).tag(AVPSettings.SubtitleSize.large)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                hint("Tamaño de la letra de los subtítulos. Grande puede llenar la vista con las líneas largas. Recomendado: Pequeño (o Medio si no los lees bien). Se aplica al arrancar el juego.",
                     "Subtitle text size. Large can fill the view with long lines. Recommended: Small (or Medium if you cannot read them well). Applied at game start.")
            }
            VStack(alignment: .leading, spacing: 4) {
                Toggle(AVPL("Altura real (detecta el suelo)", "Real height (detects the floor)"), isOn: $s.realFloor)
                hint("El visor mide el suelo de tu habitación y tu altura sobre él cada pocos segundos, sentado o de pie, para que la altura de Alyx sea la tuya. La altura del jugador pasa a ser un ajuste fino. Pide permiso de detección del entorno la primera vez. Recomendado: activado.",
                     "The headset measures your room's floor and your height above it every few seconds, seated or standing, so Alyx's height matches yours. Player height becomes a fine adjustment. Asks for the surroundings-sensing permission once. Recommended: on.")
            }
            VStack(alignment: .leading, spacing: 4) {
                Stepper(AVPL("Altura del jugador: \(Int(s.heightOffsetCm)) cm", "Player height: \(Int(s.heightOffsetCm)) cm"),
                        value: $s.heightOffsetCm, in: -60...30, step: 5)
                hint("Ajuste fino de la altura de Alyx. Negativo = Alyx más baja (jugando sentado, o si el suelo del juego queda demasiado lejos de las manos); positivo = más alta. Recomendado: 0 cm. Se aplica en vivo desde la pausa.",
                     "Fine adjustment of Alyx's height. Negative = Alyx lower (playing seated, or when the game's floor sits too far from your hands); positive = taller. Recommended: 0 cm. Applied live from the pause menu.")
            }
            VStack(alignment: .leading, spacing: 4) {
                Toggle(AVPL("Sincronizar partidas con Steam Cloud", "Sync saves with Steam Cloud"), isOn: $s.cloudSync)
                hint("Guarda tus partidas en tu cuenta de Steam y recupera las de otros dispositivos. Apágalo solo si no quieres que se sincronicen. Recomendado: activado.",
                     "Stores your saves in your Steam account and fetches those from other devices. Turn it off only if you do not want them synced. Recommended: on.")
            }
            VStack(alignment: .leading, spacing: 4) {
                Toggle(AVPL("Dedos reales (seguimiento de manos del visor)", "Real fingers (the headset's hand tracking)"), isOn: $s.handFingers)
                hint("Los dedos del jugador siguen a tus dedos de verdad (como con los mandos Index de Valve) cuando el visor ve la mano; pide permiso de seguimiento de manos la primera vez. Con un mando Sense en la mano el visor NO da el seguimiento de esa mano (medido): solo actúa con las manos libres. Recomendado: activado. Se aplica al arrancar el juego.",
                     "The player's fingers follow your own (as with Valve's Index controllers) when the headset sees the hand; asks for the hand-tracking permission once. With a Sense controller in the hand the headset does NOT track that hand (measured): it only acts with free hands. Recommended: on. Applied at game start.")
            }
            VStack(alignment: .leading, spacing: 4) {
                Toggle(AVPL("Manos adelantadas al centro de cada imagen", "Hands predicted to the middle of each picture"), isOn: $s.handHoldPredict)
                hint("Cada imagen del juego se ve 2 o 3 refrescos; las manos se colocan donde estarán a mitad de ese tiempo para que vayan menos por detrás de las tuyas. Recomendado: activado.",
                     "Each game picture is shown for 2 or 3 refreshes; the hands are placed where they will be halfway through, so they trail yours less. Recommended: on.")
            }
        } header: {
            Text(AVPL("Juego y controles", "Game and controls"))
        }
    }

    private var resetSection: some View {
        Section {
            Button(AVPL("Restablecer todos los ajustes", "Reset all settings"), role: .destructive) { s.resetToDefaults() }
        } footer: {
            Text(AVPL("Devuelve los ajustes de esta pantalla a sus valores originales. Úsalo si has tocado cosas y el juego va peor. No toca la carpeta AVP ni el certificado.",
                      "Puts the settings of this screen back to their original values. Use it if you changed things and the game got worse. It does not touch the AVP folder or the certificate."))
        }
    }

    private var diagnostics: some View {
        Section {
            DisclosureGroup(AVPL("Diagnóstico (solo si te lo piden)", "Diagnostics (only when asked)"), isExpanded: $diagnosticsOpen) {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(AVPL("Capturas de diagnóstico", "Diagnostic captures"), isOn: $s.diagCaptures)
                    hint("Guarda imágenes de los ojos y un volcado pase a pase en Logs Alyx; con ellas activas, L3 + R3 a la vez guarda el fallo que estés viendo. Cada captura detiene el juego un instante. Recomendado: desactivado (solo si te lo piden). Se aplica al arrancar el juego.",
                         "Saves eye pictures and a pass-by-pass dump in Logs Alyx; with them on, L3 + R3 together saves the glitch you are seeing. Each capture stalls the game for an instant. Recommended: off (only when asked). Applied at game start.")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(AVPL("Medir el tiempo de GPU por pase", "Per-pass GPU timing"), isOn: $s.gpuPassProfiling)
                    hint("Anota en el registro cuánto tarda la GPU en cada pase de dibujo. Sirve para buscar qué ralentiza el juego y cuesta algo de rendimiento. Recomendado: desactivado (solo si te lo piden). Se aplica al arrancar el juego.",
                         "Writes to the log how long the GPU takes in each draw pass. It is for finding what slows the game down and costs some performance. Recommended: off (only when asked). Applied at game start.")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(AVPL("Diagnóstico de coste por shader", "Per-shader cost diagnostic"), isOn: $s.shaderKnock)
                    hint("Dentro de la partida pulsa L3 + R3 para empezar. Durante 1–2 minutos oculta por turnos grupos de objetos para medir cuánto cuesta cada shader (verás parpadeos). Los pasos se marcan en pantalla. Solo para diagnóstico.",
                         "In game, press L3 + R3 to start. For 1-2 minutes it hides groups of objects in turns to measure what each shader costs (you will see flicker). The steps are ticked off on screen. For diagnostics only.")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(AVPL("Occlusion culling medido (consultas de GPU)", "Measured occlusion culling (GPU queries)"), isOn: $s.occlusionQueries)
                    hint("El juego deja de dibujar lo que la GPU comprueba que queda oculto tras otros objetos (menos carga). Apagado, todo cuenta como visible. Apágalo solo si ves objetos que desaparecen o parpadean. Recomendado: activado.",
                         "The game stops drawing what the GPU finds hidden behind other objects (less load). Off, everything counts as visible. Turn it off only if you see objects vanishing or flickering. Recommended: on.")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(AVPL("Un pase por ojo (experimental)", "One pass per eye (experimental)"), isOn: $s.splitViews)
                    hint("Dibuja cada ojo por separado para aliviar la geometría; en caliente",
                         "Draws each eye separately to ease the geometry; applied live")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(AVPL("Amplificación con recorte (experimental)", "Amplification with clipping (experimental)"), isOn: $s.amplifyClip)
                    hint("Los shaders de vértices con recorte que no depende del ojo siguen amplificados. Pensado para probarlo junto con «Un pase por ojo» y sacar el pase principal de HeavyGeometry; sin medir en el visor. Solo actúa con la amplificación de vértices activa. Recomendado: desactivado. Se aplica al arrancar el juego.",
                         "Vertex shaders with clipping that does not depend on the eye stay amplified. Meant to be tried together with «One pass per eye» to take the main pass out of HeavyGeometry; not measured on the headset. Only acts with vertex amplification on. Recommended: off. Applied at game start.")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(AVPL("Posición invariante (desactivar para probar rendimiento)", "Invariant position (turn off to test performance)"), isOn: $s.invariantPos)
                    hint("El motor la fuerza para evitar z-fighting entre pases. Desactivarla puede dar más rendimiento en geometría pesada, pero puede causar parpadeo de profundidad; sin medir en el visor. Recomendado: activado. Se aplica al arrancar el juego.",
                         "The engine forces it to avoid z-fighting between passes. Turning it off may give more performance on heavy geometry, but can cause depth flicker; not measured on the headset. Recommended: on. Applied at game start.")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(AVPL("Ritmo sin recuperación", "Pacing without catch-up"), isOn: $s.paceRephase)
                    hint("Tras un fotograma tarde, el siguiente espera al refresco que le toca en lugar de adelantarse para recuperar (evita un fotograma de solo 2 refrescos). Recomendado: activado; en caliente",
                         "After a late frame, the next one waits for its refresh instead of running ahead to catch up (avoids a frame shown for only 2 refreshes). Recommended: on; applied live")
                }
                VStack(alignment: .leading, spacing: 4) {
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
                    hint("Si un efecto o un objeto dejó de dibujarse porque colgó la GPU una vez, el motor lo aparta (cuarentena). Este botón le da otra oportunidad en el próximo arranque. El número es cuántos hay apartados; con 0 no hace nada.",
                         "If an effect or object stopped being drawn because it hung the GPU once, the engine sets it aside (quarantine). This button gives it another chance at the next launch. The number is how many are set aside; with 0 it does nothing.")
                }
            }
        } footer: {
            Text(AVPL("Déjalo como está salvo que se te pida para un registro.",
                      "Leave it as it is unless you are asked for a log."))
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
