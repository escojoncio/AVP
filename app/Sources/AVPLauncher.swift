// AVP: the launcher window. AVP folder, Steam sign-in (password + Steam Guard), ownership, the
// download, the preparation steps, settings (certificate and the settings that rule over the
// game), logs, and Play. Once the game is prepared and started the window becomes Klepton's
// BootView, which boots it and opens the immersive space.

import Combine
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The launcher window's scene id (dismissed while the game's immersive space is open).
enum AVPMainWindow {
    static let id = "main"
}

struct AVPRootView: View {
    @ObservedObject private var model = AVPModel.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if model.paused {
                AVPPausedView()
            } else if model.ended {
                AVPEndedView()
            } else if model.running {
                BootView()
            } else {
                AVPLauncherView()
            }
        }
        .onChange(of: scenePhase) { _, p in model.scenePhaseChanged(p) }
    }
}

struct AVPLauncherView: View {
    @ObservedObject private var model = AVPModel.shared
    @State private var pickingFolder = false
    @State private var showSettings = false

    var body: some View {
        // Split composition: the artwork on the left, unobstructed; every control in its own column.
        GeometryReader { geo in
            HStack(spacing: 0) {
                AVPBackdrop()
                    .frame(width: geo.size.width * 0.6, height: geo.size.height)
                    .clipped()
                controlColumn
                    .frame(width: geo.size.width * 0.4, height: geo.size.height)
                    .background {
                        LinearGradient(colors: [Color(red: 0.11, green: 0.12, blue: 0.15), AVPTheme.navy],
                                       startPoint: .top, endPoint: .bottom)
                    }
            }
        }
        .ignoresSafeArea()
        .onAppear { model.setBatteryPolling(true) }
        .onDisappear { model.setBatteryPolling(false) }
        .sheet(isPresented: $showSettings) { AVPSettingsView() }
        .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.choose(url) }
        }
    }

    private var controlColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 12)
            Divider().opacity(0.3)
            Group {
                if model.certificate == nil {
                    AVPCertificateGate()   // first step, before folder, Steam and download; gone once imported
                } else {
                switch model.phase {
                case .needFolder: noFolder
                case .signIn: AVPSignInView()
                case .checkingOwnership:
                    VStack(spacing: 16) {
                        ProgressView().controlSize(.large)
                        Text(AVPL("Comprobando tu copia de Half-Life: Alyx…", "Checking your copy of Half-Life: Alyx…"))
                            .font(.title3).multilineTextAlignment(.center)
                    }
                    .padding(32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .notOwned: notOwned
                case .library: AVPLibraryView()
                }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            if let message = model.message {
                HStack(alignment: .top) {
                    Text(message).font(.callout).foregroundStyle(.orange)
                    Spacer(minLength: 8)
                    Button { model.message = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                }
                .padding(16)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 20).padding(.bottom, 20)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Half-Life: Alyx").font(.title3.weight(.bold)).lineLimit(1)
            Spacer(minLength: 8)
            if model.phase == .library || model.phase == .notOwned {
                Menu {
                    if !model.accountName.isEmpty { Text(model.accountName) }
                    Button(role: .destructive) { model.signOut() } label: {
                        Label(AVPL("Cerrar sesión", "Sign out"), systemImage: "rectangle.portrait.and.arrow.right")
                    }
                } label: {
                    Label(model.accountName.isEmpty ? AVPL("Cuenta", "Account") : model.accountName, systemImage: "person.crop.circle")
                        .lineLimit(1)
                }
                .buttonStyle(.borderless)
            }
            ShareLink(items: AVPLog.shareable) { Label(AVPL("Registros", "Logs"), systemImage: "doc.text").labelStyle(.iconOnly) }
                .buttonStyle(.borderless)
            Button { showSettings = true } label: { Label(AVPL("Ajustes", "Settings"), systemImage: "gearshape").labelStyle(.iconOnly) }
                .buttonStyle(.borderless)
        }
    }

    private var noFolder: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder.badge.questionmark").font(.system(size: 44))
            Text(AVPL("Elige la carpeta AVP", "Choose the AVP folder")).font(.title)
            Text(AVPL("Créala una vez en «En mi Apple Vision Pro» (app Archivos). Dentro irán el juego, la caché y los registros, fuera de la app: no se pierden al reinstalarla.",
                      "Make it once in “On My Apple Vision Pro” (Files app). The game, the cache and the logs go inside it, outside the app: they survive reinstalling it."))
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button(AVPL("Elegir carpeta", "Choose folder")) { pickingFolder = true }.buttonStyle(AVPPillButtonStyle())
        }
        .padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var notOwned: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill").font(.system(size: 56)).foregroundStyle(.orange)
            Text(AVPL("Esta cuenta no tiene Half-Life: Alyx", "This account does not own Half-Life: Alyx")).font(.title)
            Text(AVPL("AVP solo descarga el juego a cuentas de Steam que lo han comprado. Inicia sesión con la cuenta que lo tiene.",
                      "AVP only downloads the game for Steam accounts that bought it. Sign in with the account that owns it."))
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button(AVPL("Cambiar de cuenta", "Switch account")) { model.signOut() }.buttonStyle(AVPPillButtonStyle())
        }
        .padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Sign-in

struct AVPSignInView: View {
    @ObservedObject private var model = AVPModel.shared
    @State private var account = ""
    @State private var password = ""
    @State private var code = ""

    var body: some View {
        VStack(spacing: 20) {
            Text(AVPL("Inicia sesión en Steam", "Sign in to Steam")).font(.title.bold())
            switch model.signInStep {
            case .idle, .working:
                VStack(spacing: 12) {
                    TextField(AVPL("Nombre de cuenta", "Account name"), text: $account)
                        .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField(AVPL("Contraseña", "Password"), text: $password).textContentType(.password)
                }
                .textFieldStyle(.roundedBorder)
                if model.signInStep == .working {
                    ProgressView()
                } else {
                    Button(AVPL("Iniciar sesión", "Sign in")) { model.signIn(account: account, password: password); password = "" }
                        .buttonStyle(AVPPillButtonStyle())
                        .disabled(account.isEmpty || password.isEmpty)
                }
                Text(AVPL("Conexión oficial con Steam. La contraseña se cifra con la clave de Steam y no se guarda; solo se guarda el token de sesión en el llavero.",
                          "Official connection to Steam. The password is encrypted with Steam's key and never stored; only the session token is kept in the keychain."))
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            case .approveInApp(let canEnterCode):
                ProgressView().controlSize(.large)
                Text(AVPL("Aprueba el inicio de sesión en la app Steam de tu móvil.", "Approve the sign-in in the Steam app on your phone."))
                    .font(.title3).multilineTextAlignment(.center)
                Text(AVPL("Esperando la aprobación…", "Waiting for approval…")).foregroundStyle(.secondary)
                HStack {
                    if canEnterCode { Button(AVPL("Usar un código", "Use a code instead")) { model.useCodeInstead() } }
                    Button(AVPL("Cancelar", "Cancel"), role: .cancel) { model.cancelSignIn() }
                }
            case .enterCode(let email):
                Text(email.map { AVPL("Escribe el código que Steam ha enviado a \($0).", "Type the code Steam emailed to \($0).") }
                     ?? AVPL("Escribe el código de Steam Guard de la app Steam.", "Type the Steam Guard code from the Steam app."))
                    .multilineTextAlignment(.center)
                TextField(AVPL("Código", "Code"), text: $code)
                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                HStack {
                    Button(AVPL("Enviar", "Submit")) { model.submitCode(code); code = "" }
                        .buttonStyle(.borderedProminent).disabled(code.count < 5)
                    Button(AVPL("Cancelar", "Cancel"), role: .cancel) { model.cancelSignIn() }
                }
            }
            if let e = model.signInError { Text(e).foregroundStyle(.orange) }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Library (download, preparation, Play)

struct AVPLibraryView: View {
    @ObservedObject private var model = AVPModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack { savesBadge; Spacer() }.font(.callout)
                    AVPControllerPills(controllers: model.senseControllers)
                    downloadCard
                    if case .installed = model.install { prepareCard }
                }
                .padding(24)
            }
            playCard
                .padding(.horizontal, 24).padding(.vertical, 20)
                .background(Color.black.opacity(0.25))
        }
    }

    @ViewBuilder private var savesBadge: some View {
        switch model.saves {
        case .idle: EmptyView()
        case .off: Label(AVPL("Nube apagada", "Cloud off"), systemImage: "icloud.slash").foregroundStyle(.secondary)
        case .syncing(let t): Label(AVPL("Partidas: ", "Saves: ") + t, systemImage: "arrow.triangle.2.circlepath.icloud")
        case .synced: Label(AVPL("Partidas al día", "Saves up to date"), systemImage: "checkmark.icloud")
        case .failed(let why): Label(AVPL("Nube: ", "Cloud: ") + why, systemImage: "exclamationmark.icloud").foregroundStyle(.orange)
        }
    }

    private var downloadCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(AVPL("Descarga", "Download"), systemImage: "arrow.down.circle").font(.title2.bold())
            switch model.install {
            case .unknown, .planning:
                HStack { ProgressView(); Text(AVPL("Preguntando a Steam…", "Asking Steam…")) }
            case .notInstalled:
                Text(AVPL("Build \(model.buildID) · \(AVPLog.bytes(model.downloadBytes)) (contenido + binarios ARM64 de Linux)",
                          "Build \(model.buildID) · \(AVPLog.bytes(model.downloadBytes)) (content + Linux ARM64 binaries)"))
                    .foregroundStyle(.secondary)
                if let s = model.spaceProblem { Text(s).foregroundStyle(.orange) }
                Button { model.startInstall() } label: {
                    Label(AVPL("Descargar", "Download"), systemImage: "arrow.down").font(.title3.weight(.semibold))
                }
                .buttonStyle(AVPPillButtonStyle()).disabled(model.spaceProblem != nil)
            case .downloading(let p):
                progress(p)
                Button { model.pauseInstall() } label: { Label(AVPL("Pausar", "Pause"), systemImage: "pause.fill") }
                    .buttonStyle(AVPPillButtonStyle(prominent: false))
            case .paused(let p):
                progress(p)
                Button { model.startInstall() } label: { Label(AVPL("Continuar", "Resume"), systemImage: "play.fill") }
                    .buttonStyle(AVPPillButtonStyle())
            case .installed(let update):
                Label(update ? AVPL("Descargado (hay otra build en Steam; AVP usa la build probada)", "Downloaded (Steam has another build; AVP uses the tested one)")
                             : AVPL("Descargado · build \(model.buildID)", "Downloaded · build \(model.buildID)"),
                      systemImage: "checkmark.circle").foregroundStyle(AVPTheme.ok)
            case .failed(let why):
                Text(why).foregroundStyle(.orange)
                Button(AVPL("Reintentar", "Retry")) { Task { await model.refreshInstall() } }
                    .buttonStyle(AVPPillButtonStyle(prominent: false))
            }
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 20))
    }

    private func progress(_ p: DownloadProgress) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(Int(p.fraction * 100)) %").font(.system(size: 34, weight: .bold)).monospacedDigit()
                Spacer()
            }
            AVPBar(fraction: p.fraction)
            HStack {
                Text("\(AVPLog.bytes(p.doneBytes)) / \(AVPLog.bytes(p.totalBytes))")
                Spacer()
                if p.bytesPerSecond > 0 { Text("\(AVPLog.bytes(UInt64(p.bytesPerSecond)))/s") }
                if let s = p.secondsLeft { Text(AVPL("quedan ", "left ") + Duration.seconds(s).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))) }
            }
            .font(.caption).foregroundStyle(.secondary)
            Text(AVPL("Puedes salir de la app: el sistema sigue descargando en segundo plano.",
                      "You can leave the app: the system keeps downloading in the background."))
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var prepareCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(AVPL("Preparación en el visor", "Preparation on the headset"), systemImage: "wrench.and.screwdriver").font(.title2.bold())
            ForEach(Array(AVPPrepare.stepNames.enumerated()), id: \.offset) { i, name in
                HStack {
                    Image(systemName: stepIcon(i)).foregroundStyle(stepColor(i))
                    Text(name)
                    if model.preparing && model.prepStep == i {
                        AVPBar(fraction: model.prepFraction).frame(maxWidth: 220)
                    }
                }
            }
            if model.preparing { Text(model.prepText).font(.caption).foregroundStyle(.secondary) }
            if !model.preparing {
                Button(model.prepared ? AVPL("Comprobar preparación", "Check preparation") : AVPL("Preparar ahora", "Prepare now")) {
                    model.prepare(thenPlay: false)
                }
                .buttonStyle(AVPPillButtonStyle(prominent: !model.prepared))
                .disabled(model.certificate == nil)
            }
            Text(AVPL("Solo la primera vez tarda: lo hecho se guarda y nunca se repite.", "Only slow the first time: finished work is kept and never redone."))
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 20))
    }

    private func stepIcon(_ i: Int) -> String {
        if model.preparing { return i < model.prepStep ? "checkmark.circle.fill" : i == model.prepStep ? "circle.dotted" : "circle" }
        return model.prepared ? "checkmark.circle.fill" : "circle"
    }

    private func stepColor(_ i: Int) -> Color {
        if model.preparing { return i < model.prepStep ? AVPTheme.ok : i == model.prepStep ? AVPTheme.accent : .secondary }
        return model.prepared ? AVPTheme.ok : .secondary
    }

    private var playCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let issue = model.controllerIssue {
                Label(issue, systemImage: "gamecontroller").foregroundStyle(.orange)
                if model.controllerAccess == .denied {
                    Button(AVPL("Abrir Ajustes", "Open Settings")) {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    .buttonStyle(AVPPillButtonStyle(prominent: false))
                }
            } else {
                Label(AVPL("Dos mandos PS VR2 Sense conectados", "Two PS VR2 Sense controllers connected"), systemImage: "gamecontroller.fill")
                    .foregroundStyle(AVPTheme.ok)
            }
            Button {
                model.play()
            } label: {
                Label(model.launching ? AVPL("Sincronizando partidas…", "Syncing saves…") : AVPL("Jugar", "Play"), systemImage: "play.fill")
                    .font(.title.weight(.bold)).padding(.horizontal, 28).padding(.vertical, 4)
            }
            .buttonStyle(AVPPillButtonStyle())
            .shadow(color: .white.opacity(model.canPlay ? 0.35 : 0), radius: 22)
            .disabled(!model.canPlay)
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 20))
    }
}

// MARK: - Controller battery pills

/// One compact pill per connected PS VR2 Sense controller: hand, battery level, charging state.
struct AVPControllerPills: View {
    let controllers: [AVPModel.SenseController]

    var body: some View {
        if !controllers.isEmpty {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { ForEach(controllers) { c in pill(c) } }
                VStack(alignment: .leading, spacing: 8) { ForEach(controllers) { c in pill(c) } }
            }
            .animation(.easeOut(duration: 0.3), value: controllers)
        }
    }

    private func handText(_ h: AVPModel.SenseController.Hand) -> String {
        switch h {
        case .left: return AVPL("Izq.", "Left")
        case .right: return AVPL("Der.", "Right")
        case .unknown(let n): return AVPL("Mando \(n)", "Controller \(n)")
        }
    }

    private func batterySymbol(_ level: Float) -> String {
        switch level {
        case ..<0.13: return "battery.0percent"
        case ..<0.38: return "battery.25percent"
        case ..<0.63: return "battery.50percent"
        case ..<0.88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    private func pill(_ c: AVPModel.SenseController) -> some View {
        let low = (c.level ?? 1) < 0.2 && c.state != .charging
        let tint: Color = low ? AVPTheme.warn : .white
        return HStack(spacing: 8) {
            Image(systemName: "gamecontroller.fill").foregroundStyle(.white.opacity(0.8))
            Text(handText(c.hand)).fontWeight(.semibold)
            if let level = c.level {
                Image(systemName: c.state == .charging ? "battery.100percent.bolt" : batterySymbol(level))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tint)
                Text(c.state == .full ? AVPL("Llena", "Full") : "\(Int((level * 100).rounded())) %")
                    .monospacedDigit().foregroundStyle(tint)
                if c.state == .charging {
                    Image(systemName: "bolt.fill").font(.caption).foregroundStyle(AVPTheme.ok)
                }
            } else {
                Text("—").foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color.white.opacity(0.08), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Pause

/// The game is held (left PS held 1 s, or the system closed the space with Home/PS/Crown). Settings changed here
/// that can apply live do so on "Volver al juego"; the rest are marked as applying on the next start.
struct AVPPausedView: View {
    @ObservedObject private var model = AVPModel.shared
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var showSettings = false
    @State private var resuming = false

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                AVPBackdrop()
                    .frame(width: geo.size.width * 0.6, height: geo.size.height)
                    .clipped()
                VStack(alignment: .leading, spacing: 18) {
                    Text("Half-Life: Alyx").font(.title3.weight(.bold))
                    Label(AVPL("Juego en pausa", "Game paused"), systemImage: "pause.circle.fill").font(.largeTitle.bold())
                    Text(AVPL("La partida sigue cargada. Puedes cambiar ajustes gráficos y volver sin reiniciar.",
                              "Your game is still loaded. Change graphics settings and go back without restarting."))
                        .foregroundStyle(.secondary)
                    Button {
                        resuming = true
                        Task { @MainActor in
                            await Lifecycle.resumeGame { dismissWindow(id: AVPMainWindow.id) }
                            resuming = false
                        }
                    } label: {
                        Label(AVPL("Volver al juego", "Back to the game"), systemImage: "play.fill")
                    }
                    .buttonStyle(AVPPillButtonStyle(prominent: true))
                    .disabled(resuming)
                    Button { showSettings = true } label: {
                        Label(AVPL("Ajustes", "Settings"), systemImage: "gearshape")
                    }
                    .buttonStyle(AVPPillButtonStyle(prominent: false))
                    Button(role: .destructive) { Lifecycle.quit() } label: {
                        Label(AVPL("Salir del juego", "Quit the game"), systemImage: "xmark.circle")
                    }
                    .buttonStyle(AVPPillButtonStyle(prominent: false))
                    Text(AVPL("Al volver se aplican: calidad de los bordes del foveado, suavizado VPKTAA (intensidad y nitidez) y contador de FPS. Foveado sí/no, zona nítida, resolución, texturas, anisotrópico e idioma se aplican al reiniciar el juego.",
                              "Applied on return: foveation edge quality, VPKTAA smoothing (strength and sharpness) and the FPS counter. Foveation on/off, sharp zone, resolution, textures, anisotropy and language apply on the next game start."))
                        .font(.caption).foregroundStyle(.tertiary)
                    Spacer()
                    AVPControllerPills(controllers: model.senseControllers)
                }
                .padding(28)
                .frame(width: geo.size.width * 0.4, height: geo.size.height, alignment: .topLeading)
                .background {
                    LinearGradient(colors: [Color(red: 0.11, green: 0.12, blue: 0.15), AVPTheme.navy],
                                   startPoint: .top, endPoint: .bottom)
                }
            }
        }
        .ignoresSafeArea()
        .onAppear { model.setBatteryPolling(true) }
        .onDisappear { model.setBatteryPolling(false) }
        .sheet(isPresented: $showSettings) { AVPSettingsView() }
    }
}

// MARK: - Boot / ended (used by Klepton's BootView and the root view)

/// What the player sees while the game boots: a quiet animation, the pipeline progress and the status.
struct AVPLoadingView: View {
    let running: Bool
    let finished: Bool
    let succeeded: Bool
    let openedSpace: Bool
    let status: String
    let showLog: () -> Void
    @State private var pulse = false
    @State private var pipelines = (done: 0, total: 0)
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    private var failed: Bool { finished && !succeeded }
    private var phrase: String {
        if failed { return AVPL("No se pudo iniciar el juego", "The game could not start") }
        if finished || openedSpace { return AVPL("Iniciando VR…", "Starting VR…") }
        if pipelines.total > 0 && pipelines.done < pipelines.total {
            return AVPL("Preparando shaders \(pipelines.done) / \(pipelines.total)", "Preparing shaders \(pipelines.done) / \(pipelines.total)")
        }
        if running { return AVPL("Cargando juego…", "Loading game…") }
        return AVPL("Preparando…", "Preparing…")
    }

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            ZStack {
                Circle().fill(.thinMaterial).frame(width: 140, height: 140)
                    .scaleEffect(pulse ? 1.08 : 0.94).opacity(pulse ? 0.9 : 0.5)
                Image(systemName: failed ? "exclamationmark.triangle.fill" : "visionpro")
                    .font(.system(size: 54, weight: .light))
                    .foregroundStyle(failed ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.primary))
            }
            .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
            Text("Half-Life: Alyx").font(.largeTitle.bold())
            VStack(spacing: 10) {
                if !failed {
                    if pipelines.total > 0 && pipelines.done < pipelines.total {
                        ProgressView(value: Double(pipelines.done), total: Double(pipelines.total)).frame(maxWidth: 360)
                    } else {
                        ProgressView().controlSize(.large)
                    }
                }
                Text(phrase).font(.title3).foregroundStyle(.secondary)
                if failed, !status.isEmpty {
                    Text(status).font(.callout).foregroundStyle(.orange).multilineTextAlignment(.center)
                }
            }
            Spacer()
            HStack(spacing: 16) {
                Button(action: showLog) { Label(AVPL("Ver registro", "Show log"), systemImage: "doc.text.magnifyingglass") }
                    .buttonStyle(.bordered)
                ShareLink(items: AVPLog.shareable) { Label(AVPL("Compartir registros", "Share logs"), systemImage: "square.and.arrow.up") }
                    .buttonStyle(.bordered)
            }
            .font(.callout)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
        .onReceive(timer) { _ in pipelines = AlyxBoot.pipelineProgress() }
    }
}

/// Shown when the game's immersive space has closed. The runtime boots a guest once per process, so
/// playing again needs the app to start again; the next start syncs the saves to Steam Cloud.
struct AVPEndedView: View {
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "checkmark.circle").font(.system(size: 60, weight: .light)).foregroundStyle(.secondary)
            Text("Half-Life: Alyx").font(.largeTitle.bold())
            Text(AVPL("Partida cerrada. Las partidas se suben a Steam Cloud al abrir la app de nuevo. Para volver a jugar, cierra la app y ábrela.",
                      "Game closed. Saves go up to Steam Cloud when the app opens again. To play again, close the app and open it."))
                .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 640)
            Spacer()
            HStack(spacing: 16) {
                ShareLink(items: AVPLog.shareable) { Label(AVPL("Compartir registros", "Share logs"), systemImage: "square.and.arrow.up") }
                    .buttonStyle(.bordered)
                Button {
                    AVPLog.log("Cerrar app tras la partida")
                    AVPLog.mirrorToFolder()
                    fflush(nil)
                    exit(0)
                } label: { Label(AVPL("Cerrar app", "Close app"), systemImage: "xmark.circle") }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

/// First screen until a signing certificate is stored: the .p12 the app was signed with, and its password.
/// Without it the converted libraries cannot be signed, so nothing else (Steam, download) is offered before.
struct AVPCertificateGate: View {
    @ObservedObject private var model = AVPModel.shared
    @State private var importing = false
    @State private var p12: Data?
    @State private var fileName = ""
    @State private var password = ""
    @State private var result: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(AVPL("Certificado de firma", "Signing certificate"), systemImage: "signature").font(.title2.bold())
            Text(AVPL("Primer paso: importa el .p12 con el que firmaste esta app. Con él se firman en el visor las librerías del juego; sin él no podría arrancar nada de lo que se descargue.",
                      "First step: import the .p12 you signed this app with. The game's libraries are signed with it on the headset; without it nothing downloaded could run."))
                .foregroundStyle(.secondary)
            Button(p12 == nil ? AVPL("Elegir .p12…", "Choose .p12…") : fileName) { importing = true }
                .buttonStyle(AVPPillButtonStyle(prominent: p12 == nil))
            if let data = p12 {
                SecureField(AVPL("Contraseña del .p12", ".p12 password"), text: $password)
                    .textFieldStyle(.roundedBorder)
                Button(AVPL("Guardar certificado", "Save certificate")) {
                    do {
                        result = try AVPSigner.store(p12: data, password: password)
                        AVPLog.log("Certificado: importado al inicio (\(fileName))")
                        model.refreshCertificate()
                        p12 = nil; password = ""
                    } catch {
                        result = error.localizedDescription
                        AVPLog.log("Certificado: fallo al importar: \(error.localizedDescription)")
                    }
                }
                .buttonStyle(AVPPillButtonStyle(prominent: true))
            }
            if let result { Text(result).font(.callout).foregroundStyle(.orange) }
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "p12") ?? .data, .data]) { r in
            if case .success(let url) = r {
                let scoped = url.startAccessingSecurityScopedResource()
                p12 = try? Data(contentsOf: url)
                if scoped { url.stopAccessingSecurityScopedResource() }
                fileName = url.lastPathComponent
                result = p12 == nil ? AVPL("No se pudo leer el archivo.", "The file could not be read.") : nil
            }
        }
    }
}
