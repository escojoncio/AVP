// AVP: «Laboratorio del motor». One switch per engine optimisation (kl_gpu_time.m: kl_engine_set_opts), live from the
// pause menu, and the automatic A/B test on demand (kl_abtest_start) that measures them and keeps the ones that save.
// Persistence: AVPSettings.lab* (avp.lab.* keys), applied at launch and live.

import SwiftUI

struct AVPEngineLabView: View {
    @ObservedObject private var s = AVPSettings.shared
    @ObservedObject private var model = AVPModel.shared
    @State private var phase: Int32 = 0
    @State private var left: Int32 = 0
    @State private var available = false
    @State private var trimBlocked = false
    @State private var asked: String?
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    /// The engine bit each switch stands for (kl_gpu_time.h): 0 producer-only waits, 2 eye trim, 3 gather copies,
    /// 4 fuse clears, 5 state elision. Bit 1 (clear skip) is not here and never will be.
    private struct Item {
        let bit: Int32
        let title: String
        let what: String
        let byDefault: Bool
    }

    private var items: [Item] {
        [
            Item(bit: 4, title: AVPL("Fusionar borrados", "Fuse clears"),
                 what: AVPL("Junta el borrado de una imagen con el primer dibujo que la usa, en vez de hacerlo en un paso aparte (p. ej. el mapa de sombras). Ahorro: 0–2,5 ms de GPU.",
                            "Merges the clearing of an image with the first draw that uses it, instead of doing it in a separate step (e.g. the shadow map). Saving: 0–2.5 ms of GPU."),
                 byDefault: false),
            Item(bit: 3, title: AVPL("Juntar copias", "Gather copies"),
                 what: AVPL("Agrupa las copias pequeñas de cada fotograma en un solo paso. Ahorro: 0,4–1,2 ms de GPU (sobre todo en menús).",
                            "Groups each frame's small copies into a single step. Saving: 0.4–1.2 ms of GPU (mostly in menus)."),
                 byDefault: false),
            Item(bit: 5, title: AVPL("Menos órdenes por dibujo", "Fewer commands per draw"),
                 what: AVPL("No repite al gráfico ajustes que no han cambiado entre dibujos. Ahorra CPU (0,5–2 ms), no GPU.",
                            "Does not resend to the graphics chip settings that did not change between draws. Saves CPU (0.5–2 ms), not GPU."),
                 byDefault: false),
            Item(bit: 0, title: AVPL("Esperas solo a lo necesario", "Wait only for what is needed"),
                 what: AVPL("Cada paso espera solo a los pasos de los que depende. Ahorro medido: ~0,2 ms.",
                            "Each step waits only for the steps it depends on. Measured saving: ~0.2 ms."),
                 byDefault: false),
            Item(bit: 2, title: AVPL("Recortar copia de ojos", "Trim the eye copy"),
                 what: AVPL("Copia al visor solo la parte del ojo que se ha dibujado con foveado. Ahorro: 0,4–1,1 ms de GPU (medido).",
                            "Copies to the headset only the part of the eye that was drawn with foveation. Saving: 0.4–1.1 ms of GPU (measured)."),
                 byDefault: true),
        ]
    }

    private func binding(_ bit: Int32) -> Binding<Bool> {
        switch bit {
        case 0: return $s.labProducerWaits
        case 2: return $s.labEyeTrim
        case 3: return $s.labGatherCopies
        case 4: return $s.labFuseClears
        default: return $s.labStateElide
        }
    }

    private var running: Bool {
        phase == KL_ABTEST_WAIT || phase == KL_ABTEST_CENSUS || phase == KL_ABTEST_OPTS || phase == KL_ABTEST_KNOCK
            || phase == KL_ABTEST_PAUSED
    }

    private func ms(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(1))) }

    /// The last test's verdict for one switch (only once a test has ended).
    private func resultText(_ bit: Int32) -> String? {
        // The trim cannot act while the compositor reads the whole eye image (VPKTAA / eye effects).
        if bit == 2 && trimBlocked { return AVPL("No actúa con VPKTAA activo", "Does not act with VPKTAA on") }
        guard phase == KL_ABTEST_DONE else { return nil }
        var gpu = 0.0, cpu = 0.0
        let v = kl_abtest_result(bit, &gpu, &cpu)
        switch v {
        case KL_ABV_SAVES:
            // Bit 5 saves CPU, the others GPU.
            let useCpu = bit == 5 && cpu >= 0.3
            return AVPL("Último test: ahorra \(ms(useCpu ? cpu : gpu)) ms de \(useCpu ? "CPU" : "GPU")",
                        "Last test: saves \(ms(useCpu ? cpu : gpu)) ms of \(useCpu ? "CPU" : "GPU")")
        case KL_ABV_NO_EFFECT: return AVPL("Último test: sin efecto", "Last test: no effect")
        case KL_ABV_WORSE: return AVPL("Último test: empeora", "Last test: worse")
        case KL_ABV_BREAKS: return AVPL("Último test: da problemas (se deja apagado)", "Last test: causes problems (left off)")
        case KL_ABV_INACTIVE: return AVPL("Último test: no llegó a actuar", "Last test: never acted")
        default: return AVPL("Último test: sin medir", "Last test: not measured")
        }
    }

    private var statusText: String {
        let secs = Int(left)
        switch phase {
        case KL_ABTEST_WAIT:
            return model.paused
                ? AVPL("Listo. Pulsa «Volver al juego»: el test empieza a los 4 s; quédate quieto.",
                       "Ready. Press “Back to the game”: the test starts after 4 s; stand still.")
                : AVPL("Empieza en ~\(secs) s · quédate quieto", "Starts in ~\(secs) s · stand still")
        case KL_ABTEST_CENSUS:
            return AVPL("Midiendo shaders · faltan ~\(secs) s · quédate quieto",
                        "Measuring shaders · ~\(secs) s left · stand still")
        case KL_ABTEST_OPTS:
            return AVPL("Probando los interruptores · faltan ~\(secs) s · quédate quieto",
                        "Testing the switches · ~\(secs) s left · stand still")
        case KL_ABTEST_KNOCK:
            return AVPL("Midiendo shaders uno a uno · faltan ~\(secs) s · quédate quieto",
                        "Measuring shaders one by one · ~\(secs) s left · stand still")
        case KL_ABTEST_PAUSED:
            return AVPL("En pausa (carga o juego detenido): se reanuda solo al volver al juego.",
                        "Paused (a load or the game held): it resumes by itself when you are back in the game.")
        case KL_ABTEST_DONE:
            return AVPL("Test terminado: se han activado los que ahorran y apagado los que empeoran.",
                        "Test finished: the switches that save are on and those that make things worse are off.")
        case KL_ABTEST_FAILED:
            return AVPL("El test no se pudo hacer (mira los registros).", "The test could not run (see the logs).")
        default:
            return model.paused
                ? AVPL("Sin test en marcha.", "No test running.")
                : AVPL("El test se lanza con el juego en pausa (desde su menú de pausa).",
                       "The test is started with the game paused (from its pause menu).")
        }
    }

    private func refresh() {
        phase = kl_abtest_phase()
        left = kl_abtest_seconds_left()
        available = kl_engine_available() != 0
        trimBlocked = kl_abtest_eye_trim_blocked() != 0
        if phase == KL_ABTEST_DONE { s.adoptLabResult() }
    }

    var body: some View {
        Form {
            Section {
                ForEach(items, id: \.bit) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(item.title, isOn: binding(item.bit)).disabled(running)
                        Text(item.what).font(.footnote).foregroundStyle(.secondary)
                        Text(AVPL("¿Se puede ver distinto? No debería. Si ves algo raro, apágalo y avísame.",
                                  "Can it look different? It should not. If you see anything odd, turn it off and tell me."))
                            .font(.footnote).foregroundStyle(.secondary)
                        Text(AVPL("Por defecto: \(item.byDefault ? "activado" : "apagado")",
                                  "Default: \(item.byDefault ? "on" : "off")"))
                            .font(.footnote).foregroundStyle(.secondary)
                        if let r = resultText(item.bit) {
                            Text(r).font(.footnote.weight(.semibold))
                        }
                    }
                }
            } header: {
                Text(AVPL("Interruptores", "Switches"))
            } footer: {
                Text(AVPL("Se aplican en vivo, sin reiniciar el juego, y se guardan. Los cuatro primeros son del motor gráfico; solo cambian cómo se envía el trabajo a la GPU, no lo que se dibuja.",
                          "They apply live, without restarting the game, and are saved. The first four belong to the graphics engine; they only change how work is sent to the GPU, not what is drawn."))
            }
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(AVPL("Nitidez del centro fusionada en la composición", "Centre sharpness fused into the composite"),
                           isOn: $s.labSharpFused).disabled(running)
                    Text(AVPL("Activado (fusionada): la nitidez del centro se calcula dentro del pase que compone la imagen; un pase menos por ojo. Apagado (pase aparte): como antes, con un pase propio; sirve para comparar el coste del compositor en el registro «[cp] gpu composite». Solo actúa si «Nitidez del centro» (Ajustes) es mayor que 0.",
                              "On (fused): the centre sharpening is computed inside the pass that composes the picture; one pass less per eye. Off (separate pass): as before, with a pass of its own; it lets you compare the compositor's cost in the “[cp] gpu composite” log line. It only acts if “Centre sharpness” (Settings) is above 0."))
                        .font(.footnote).foregroundStyle(.secondary)
                    Text(AVPL("Ahora: \(s.labSharpFused ? "fusionada" : "pase aparte") · Por defecto: fusionada",
                              "Now: \(s.labSharpFused ? "fused" : "separate pass") · Default: fused"))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text(AVPL("Compositor (en vivo)", "Compositor (live)"))
            } footer: {
                Text(AVPL("Se aplica al instante, sin reiniciar el juego, y se guarda. No cambia lo que se ve, solo cuánto cuesta.",
                          "It applies at once, without restarting the game, and is saved. It does not change what you see, only what it costs."))
            }
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(AVPL("Archivo de shaders compilados (requiere reiniciar el juego)",
                                "Compiled shader archive (needs a game restart)"), isOn: $s.labArchive)
                    Text(AVPL("Guarda los shaders compilados para arrancar ~15 s antes; usa más memoria. El primer arranque con él activado tarda más (guarda los shaders compilados). Se apaga solo tras 2 cierres dentro del archivo.",
                              "Saves the compiled shaders so the game starts ~15 s sooner; it uses more memory. The first launch with it on takes longer (it saves the compiled shaders). It turns itself off after 2 crashes inside the archive."))
                        .font(.footnote).foregroundStyle(.secondary)
                    if s.labArchive,
                       FileManager.default.fileExists(atPath: AVPPipelineCache.cacheDir.appendingPathComponent("archive.off").path) {
                        Text(AVPL("Desactivado tras 2 cierres; apágalo y vuelve a encenderlo para rearmar",
                                  "Disabled after 2 crashes; turn it off and on again to re-arm"))
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    Text(AVPL("Por defecto: apagado", "Default: off")).font(.footnote).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(AVPL("Ahorro de memoria MSAA (experimental, requiere reiniciar)",
                                "MSAA memory saving (experimental, needs a restart)"), isOn: $s.labMsaaDeadStore)
                    Text(AVPL("Omite guardados de MSAA que nadie lee; si ves un parpadeo o un frame corrupto, apágalo.",
                              "Skips MSAA saves that nobody reads; if you see flicker or a corrupt frame, turn it off."))
                        .font(.footnote).foregroundStyle(.secondary)
                    Text(AVPL("Por defecto: activado", "Default: on")).font(.footnote).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(AVPL("Precisión media en shaders (experimental, requiere reiniciar)",
                                "Half precision in shaders (experimental, needs a restart)"), isOn: $s.labRelaxedF16)
                    Text(AVPL("Precisión media en shaders (como en Quest): calcula en 16 bits lo que el juego marca como apto. Puede ganar GPU; si ves bandas o manchas, apágalo.",
                              "Half precision in shaders (as on Quest): computes in 16 bits what the game marks as safe. It may save GPU time; if you see banding or blotches, turn it off."))
                        .font(.footnote).foregroundStyle(.secondary)
                    Text(AVPL("Por defecto: apagado", "Default: off")).font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text(AVPL("Requieren reiniciar el juego", "Need a game restart"))
            } footer: {
                Text(AVPL("Estos cambios se guardan ahora pero no hacen nada hasta que cierres el juego (Salir) y lo abras de nuevo.",
                          "These changes are saved now but do nothing until you quit the game (Exit) and open it again."))
            }
            Section {
                Button {
                    let r = kl_abtest_start()
                    if r > 0 {
                        asked = nil
                    } else if r == 0 {
                        asked = AVPL("Ya hay un test en marcha.", "A test is already running.")
                    } else {
                        asked = AVPL("El motor cargado no tiene estos interruptores.", "The loaded engine does not have these switches.")
                    }
                    refresh()
                } label: {
                    Label(AVPL("Probar todo automáticamente", "Test everything automatically"), systemImage: "wand.and.stars")
                }
                .disabled(!model.paused || running || !available || s.capturesAtLaunch)
                if running {
                    Button(role: .destructive) {
                        kl_abtest_cancel()
                        refresh()
                    } label: {
                        Label(AVPL("Cancelar prueba", "Cancel test"), systemImage: "xmark.circle")
                    }
                }
                Text(statusText).font(.footnote)
                if s.capturesAtLaunch {
                    Text(AVPL("No disponible con «Capturas de diagnóstico» activadas: cada captura detiene el juego ~250 ms y falsearía las medidas. Apágalas en Ajustes y reinicia el juego.",
                              "Not available with “Diagnostic captures” on: each capture stalls the game ~250 ms and would skew the measurements. Turn them off in Settings and restart the game."))
                        .font(.footnote).foregroundStyle(.orange)
                }
                if let asked { Text(asked).font(.footnote).foregroundStyle(.orange) }
                if model.paused && !available {
                    Text(AVPL("El motor cargado no ofrece los interruptores (o aún no ha arrancado).",
                              "The loaded engine does not offer the switches (or has not started yet)."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Button(role: .destructive) { s.resetLab() } label: {
                    Label(AVPL("Restaurar valores por defecto", "Restore defaults"), systemImage: "arrow.uturn.backward")
                }
                .disabled(running)
            } header: {
                Text(AVPL("Prueba automática", "Automatic test"))
            } footer: {
                Text(AVPL("Quédate quieto ~1 min en un sitio representativo; al terminar se activan los que ahorran y se apagan los que empeoran (los demás se quedan como estaban). Se mide con el juego en marcha: pulsa el botón y vuelve al juego.",
                          "Stand still for ~1 min in a representative spot; when it ends the switches that save are turned on and those that make things worse are turned off (the others stay as they were). It is measured with the game running: press the button and go back to the game."))
            }
        }
        .navigationTitle(AVPL("Laboratorio del motor", "Engine lab"))
        .onAppear { s.adoptLabResult(); refresh() }
        .onReceive(timer) { _ in refresh() }
    }
}

/// The lab on its own, for the pause menu.
struct AVPEngineLabSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            AVPEngineLabView()
                .toolbar { Button(AVPL("Hecho", "Done")) { dismiss() } }
        }
    }
}
