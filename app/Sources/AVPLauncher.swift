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
            if model.ended {
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
        NavigationStack {
            Group {
                switch model.phase {
                case .needFolder: noFolder
                case .signIn: AVPSignInView()
                case .checkingOwnership:
                    VStack(spacing: 16) {
                        ProgressView().controlSize(.large)
                        Text(AVPL("Comprobando tu copia de Half-Life: Alyx…", "Checking your copy of Half-Life: Alyx…")).font(.title3)
                    }
                case .notOwned: notOwned
                case .library: AVPLibraryView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom) {
                if let message = model.message {
                    HStack {
                        Text(message).font(.callout).foregroundStyle(.orange)
                        Button { model.message = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                    }
                    .padding().glassBackgroundEffect()
                }
            }
            .navigationTitle("AVP · Half-Life: Alyx")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    ShareLink(items: AVPLog.shareable) { Label(AVPL("Registros", "Logs"), systemImage: "doc.text") }
                    Button { showSettings = true } label: { Label(AVPL("Ajustes", "Settings"), systemImage: "gearshape") }
                }
            }
            .sheet(isPresented: $showSettings) { AVPSettingsView() }
            .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result { model.choose(url) }
            }
        }
    }

    private var noFolder: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder.badge.questionmark").font(.system(size: 56))
            Text(AVPL("Elige la carpeta AVP", "Choose the AVP folder")).font(.title)
            Text(AVPL("Créala una vez en «En mi Apple Vision Pro» (app Archivos). Dentro irán el juego, la caché y los registros, fuera de la app: no se pierden al reinstalarla.",
                      "Make it once in “On My Apple Vision Pro” (Files app). The game, the cache and the logs go inside it, outside the app: they survive reinstalling it."))
                .multilineTextAlignment(.center).frame(maxWidth: 560).foregroundStyle(.secondary)
            Button(AVPL("Elegir carpeta", "Choose folder")) { pickingFolder = true }.buttonStyle(.borderedProminent)
        }
        .padding(40)
    }

    private var notOwned: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill").font(.system(size: 56)).foregroundStyle(.orange)
            Text(AVPL("Esta cuenta no tiene Half-Life: Alyx", "This account does not own Half-Life: Alyx")).font(.title)
            Text(AVPL("AVP solo descarga el juego a cuentas de Steam que lo han comprado. Inicia sesión con la cuenta que lo tiene.",
                      "AVP only downloads the game for Steam accounts that bought it. Sign in with the account that owns it."))
                .multilineTextAlignment(.center).frame(maxWidth: 560).foregroundStyle(.secondary)
            Button(AVPL("Cambiar de cuenta", "Switch account")) { model.signOut() }.buttonStyle(.borderedProminent)
        }
        .padding(40)
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
            Image(systemName: "person.crop.circle.badge.checkmark").font(.system(size: 52))
            Text(AVPL("Inicia sesión en Steam", "Sign in to Steam")).font(.largeTitle.bold())
            switch model.signInStep {
            case .idle, .working:
                VStack(spacing: 12) {
                    TextField(AVPL("Nombre de cuenta", "Account name"), text: $account)
                        .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField(AVPL("Contraseña", "Password"), text: $password).textContentType(.password)
                }
                .textFieldStyle(.roundedBorder).frame(maxWidth: 420)
                if model.signInStep == .working {
                    ProgressView()
                } else {
                    Button(AVPL("Iniciar sesión", "Sign in")) { model.signIn(account: account, password: password); password = "" }
                        .buttonStyle(.borderedProminent)
                        .disabled(account.isEmpty || password.isEmpty)
                }
                Text(AVPL("Conexión oficial con Steam. La contraseña se cifra con la clave de Steam y no se guarda; solo se guarda el token de sesión en el llavero.",
                          "Official connection to Steam. The password is encrypted with Steam's key and never stored; only the session token is kept in the keychain."))
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 520)
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
        .padding(40)
    }
}

// MARK: - Library (download, preparation, Play)

struct AVPLibraryView: View {
    @ObservedObject private var model = AVPModel.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Half-Life: Alyx").font(.extraLargeTitle2.bold())
                        Text(AVPL("Cuenta: \(model.accountName) · tienes el juego", "Account: \(model.accountName) · you own the game"))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    savesBadge
                }
                downloadCard
                if case .installed = model.install { prepareCard }
                playCard
            }
            .padding(32)
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
                Button(AVPL("Descargar", "Download")) { model.startInstall() }
                    .buttonStyle(.borderedProminent).disabled(model.spaceProblem != nil)
            case .downloading(let p):
                progress(p)
                Button(AVPL("Pausar", "Pause")) { model.pauseInstall() }
            case .paused(let p):
                progress(p)
                Button(AVPL("Continuar", "Resume")) { model.startInstall() }.buttonStyle(.borderedProminent)
            case .installed(let update):
                Label(update ? AVPL("Descargado (hay otra build en Steam; AVP usa la build probada)", "Downloaded (Steam has another build; AVP uses the tested one)")
                             : AVPL("Descargado · build \(model.buildID)", "Downloaded · build \(model.buildID)"),
                      systemImage: "checkmark.circle").foregroundStyle(.green)
            case .failed(let why):
                Text(why).foregroundStyle(.orange)
                Button(AVPL("Reintentar", "Retry")) { Task { await model.refreshInstall() } }
            }
        }
        .padding(24).frame(maxWidth: .infinity, alignment: .leading).glassBackgroundEffect()
    }

    private func progress(_ p: DownloadProgress) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: p.fraction)
            HStack {
                Text("\(AVPLog.bytes(p.doneBytes)) / \(AVPLog.bytes(p.totalBytes)) · \(Int(p.fraction * 100)) %")
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
                        ProgressView(value: model.prepFraction).frame(maxWidth: 220)
                    }
                }
            }
            if model.preparing { Text(model.prepText).font(.caption).foregroundStyle(.secondary) }
            if model.certificate == nil {
                Text(AVPL("Importa tu certificado (.p12) en Ajustes para poder firmar las librerías.",
                          "Import your certificate (.p12) in Settings to sign the libraries."))
                    .foregroundStyle(.orange)
            }
            if !model.preparing {
                Button(model.prepared ? AVPL("Comprobar preparación", "Check preparation") : AVPL("Preparar ahora", "Prepare now")) {
                    model.prepare(thenPlay: false)
                }
                .disabled(model.certificate == nil)
            }
            Text(AVPL("Solo la primera vez tarda: lo hecho se guarda y nunca se repite.", "Only slow the first time: finished work is kept and never redone."))
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(24).frame(maxWidth: .infinity, alignment: .leading).glassBackgroundEffect()
    }

    private func stepIcon(_ i: Int) -> String {
        if model.preparing { return i < model.prepStep ? "checkmark.circle.fill" : i == model.prepStep ? "circle.dotted" : "circle" }
        return model.prepared ? "checkmark.circle.fill" : "circle"
    }

    private func stepColor(_ i: Int) -> Color {
        if model.preparing { return i < model.prepStep ? .green : .secondary }
        return model.prepared ? .green : .secondary
    }

    private var playCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let issue = model.controllerIssue {
                Label(issue, systemImage: "gamecontroller").foregroundStyle(.orange)
                if model.controllerAccess == .denied {
                    Button(AVPL("Abrir Ajustes", "Open Settings")) {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
            } else {
                Label(AVPL("Dos mandos PS VR2 Sense conectados", "Two PS VR2 Sense controllers connected"), systemImage: "gamecontroller.fill")
                    .foregroundStyle(.green)
            }
            Button {
                model.play()
            } label: {
                Label(model.launching ? AVPL("Sincronizando partidas…", "Syncing saves…") : AVPL("Jugar", "Play"), systemImage: "play.fill")
                    .font(.title2).padding(.horizontal, 24).padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canPlay)
        }
        .padding(24).frame(maxWidth: .infinity, alignment: .leading).glassBackgroundEffect()
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
