// AVP: preparing Half-Life: Alyx on the headset (replaces Glovebox's Mac build). Pure data
// transforms on the player's own files, each with a stamp so finished work is never redone:
//
//   1. runtime   17 Debian arm64 packages (app/Resources/runtime-debs.json, pinned by SHA-256)
//                -> AVP/Cache/debs/*.deb -> AVP/Cache/runtime/<22 libraries> (avp_deb.c)
//   2. convert   every ELF (not symlinks) of game/bin/linuxsteamrtarm64 (the hlvr launcher included),
//                game/hlvr/bin/linuxsteamrtarm64 and the runtime libraries -> klepton-ld in process
//                -> AVP/Cache/dylibs/<stem>.dylib, one at a time (memory), unsigned: survives reinstalls.
//                <stem>: the name up to ".so", '+' -> 'x' (Glovebox mkguest_alyx.sh, Klepton's kl_image.c)
//   3. sign      copies in Library/Application Support/AVP/Signed, signed with the imported .p12
//                (VisionQuestPro's scheme, AVPSigner); all redone when the certificate changes
//   4. pipelines Glovebox's recipe + the game's shader packs -> AVP/Cache/pipelines.foz (avp_pipelines.c)
//   5. prewarm   AlyxBoot.prewarm compiles every pipeline into VPKEngine's archives before the first play
//
// Why the signed copies live inside the app: the system only accepts them as copies in the app's own
// container, signed with the app's identifier and certificate (VisionQuestPro, VPKEngine).

import CryptoKit
import Foundation

enum AVPPrepare {
    /// Bumped when the conversion changes (a new klepton-ld, a new layout): every dylib is redone.
    static let converterVersion = "avp-kld-1"
    /// Bumped when the pipeline rebuild changes.
    static let pipelinesVersion = "avp-foz-1"

    struct Prepared {
        let signed: URL
        let pipelines: URL
    }

    enum Problem: Error, LocalizedError {
        case noFolder, notInstalled
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .noFolder: return AVPL("No hay carpeta AVP.", "There is no AVP folder.")
            case .notInstalled: return AVPL("El juego no está descargado del todo.", "The game is not fully downloaded.")
            case .failed(let m): return m
            }
        }
    }

    typealias Progress = (_ step: Int, _ fraction: Double, _ text: String) -> Void
    static let stepNames: [String] = [
        AVPL("Librerías de sistema", "System libraries"),
        AVPL("Conversión", "Conversion"),
        AVPL("Firma", "Signing"),
        AVPL("Lista de pipelines", "Pipeline list"),
        AVPL("Precompilar shaders", "Precompiling shaders"),
    ]

    /// The file name a translation has on disk.
    static func stem(_ file: String) -> String {
        var s = (file as NSString).lastPathComponent
        if let r = s.range(of: ".so") { s = String(s[..<r.lowerBound]) }
        return s.replacingOccurrences(of: "+", with: "x")
    }

    // MARK: Whole run

    /// Runs every step that is not done yet. Slow the first time: call off the main thread.
    static func prepare(progress: @escaping Progress) throws -> Prepared {
        guard let cache = AVPFolder.shared.cache else { throw Problem.noFolder }
        guard let game = AVPFolder.shared.game,
              FileManager.default.fileExists(atPath: game.appendingPathComponent(".launcher-install.json").path) else {
            throw Problem.notInstalled
        }
        let identity: AVPSigner.Identity
        do { identity = try AVPSigner.storedIdentity() } catch { throw Problem.failed(error.localizedDescription) }
        let t0 = Date()
        let runtime = try runtimeLibraries(cache: cache) { progress(0, $0, $1) }
        let dylibs = try convert(game: game, runtime: runtime, cache: cache) { progress(1, $0, $1) }
        let signed = try sign(dylibs, identity: identity) { progress(2, $0, $1) }
        let foz = try pipelines(game: game, cache: cache) { progress(3, $0, $1) }
        AVPLog.log("Preparar: listo en \(Int(Date().timeIntervalSince(t0))) s")
        return Prepared(signed: signed, pipelines: foz)
    }

    /// AlyxBoot.prewarm with progress (VPKEngine compiles every pipeline of the list). Blocking.
    static func prewarm(_ paths: AVPLaunchPaths, progress: @escaping Progress) {
        // Crash guard: a marker lives while the prewarm runs. Found at the next start (same install), the last
        // prewarm never finished: once -> this one runs on 1 thread; twice or more -> skipped (the game's own
        // replay warms the cache, also on 1 thread). A new install (another bundle path) starts over.
        let marker = paths.dataDir.appendingPathComponent("prewarm.inflight")
        let install = Bundle.main.bundlePath
        var unfinished = 0
        if let text = try? String(contentsOf: marker, encoding: .utf8) {
            let parts = text.split(separator: " ", maxSplits: 1).map(String.init)
            if parts.count == 2, parts[1] == install { unfinished = Int(parts[0]) ?? 0 }
        }
        if unfinished > 0 {
            AVPLog.log("Preparar: la precompilación anterior no terminó (\(unfinished) vez/veces, cierre inesperado); "
                       + "detalles en Logs Alyx/klepton-prewarm-*.log y klepton-crash-*.log")
            kl_app_prewarm_threads(1)
        }
        if unfinished >= 2 {
            AVPLog.log("Preparar: precompilado saltado; el juego compila los shaders al arrancar (1 hilo)")
            progress(4, 1, AVPL("Shaders: se compilan al arrancar", "Shaders: compiled at start"))
            // Next start tries again on 1 thread (never stuck skipping for good).
            try? "1 \(install)".write(to: marker, atomically: true, encoding: .utf8)
            return
        }
        try? "\(unfinished + 1) \(install)".write(to: marker, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: marker) }
        let t0 = Date()
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var rc: Int32 = 0
        Thread.detachNewThread {
            rc = AlyxBoot.prewarm(paths)
            done.signal()
        }
        while done.wait(timeout: .now() + 0.25) == .timedOut {
            let p = AlyxBoot.pipelineProgress()
            let f = p.total > 0 ? Double(p.done) / Double(p.total) : 0
            progress(4, f, AVPL("Shaders \(p.done) / \(p.total)", "Shaders \(p.done) / \(p.total)"))
        }
        let p = AlyxBoot.pipelineProgress()
        progress(4, 1, AVPL("Shaders listos", "Shaders ready"))
        AVPLog.log("Preparar: precompilados \(p.done)/\(p.total) pipelines en \(Int(Date().timeIntervalSince(t0))) s"
                   + "\(unfinished > 0 ? " (1 hilo)" : "") (rc \(rc): \(String(cString: kl_app_status())))")
    }

    // MARK: 1. Runtime libraries

    struct DebSpec: Decodable {
        struct Package: Decodable { let file: String; let sha256: String; let url: String }
        let packages: [Package]
        let files: [String]
    }

    static func debSpec() throws -> DebSpec {
        guard let url = Bundle.main.url(forResource: "runtime-debs", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            throw Problem.failed(AVPL("Falta runtime-debs.json en la app.", "runtime-debs.json is missing from the app."))
        }
        return try JSONDecoder().decode(DebSpec.self, from: data)
    }

    private static func runtimeLibraries(cache: URL, progress: @escaping (Double, String) -> Void) throws -> URL {
        let fm = FileManager.default
        let spec = try debSpec()
        let out = cache.appendingPathComponent("runtime", isDirectory: true)
        let debs = cache.appendingPathComponent("debs", isDirectory: true)
        let stampURL = out.appendingPathComponent(".stamp")
        let want = spec.packages.map(\.sha256).joined(separator: ",")
        if (try? String(contentsOf: stampURL, encoding: .utf8)) == want,
           spec.files.allSatisfy({ fm.fileExists(atPath: out.appendingPathComponent($0).path) }) {
            AVPLog.log("Preparar: \(spec.files.count) librerías de sistema ya listas")
            progress(1, AVPL("Ya listas", "Already done"))
            return out
        }
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        try fm.createDirectory(at: debs, withIntermediateDirectories: true)
        var have = Set<String>()
        for (i, pkg) in spec.packages.enumerated() {
            progress(Double(i) / Double(spec.packages.count), AVPL("Descargando", "Downloading") + " \(pkg.file)")
            let deb = debs.appendingPathComponent(pkg.file)
            if (try? sha256(of: deb)) != pkg.sha256 {
                try? fm.removeItem(at: deb)
                try download(pkg.url, to: deb)
                let got = try sha256(of: deb)
                guard got == pkg.sha256 else {
                    try? fm.removeItem(at: deb)
                    throw Problem.failed(AVPL("\(pkg.file) no es el paquete esperado (SHA-256 \(got)).",
                                              "\(pkg.file) is not the expected package (SHA-256 \(got))."))
                }
                AVPLog.log("Preparar: \(pkg.file) descargado y verificado")
            }
            var err = [CChar](repeating: 0, count: 512)
            let names = spec.files.map { strdup($0) }
            defer { names.forEach { free($0) } }
            var found = [Int32](repeating: 0, count: names.count)
            let n: Int32 = names.withUnsafeBufferPointer { nb in
                nb.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: names.count) { p in
                    avp_deb_extract(deb.path, out.path, p, Int32(names.count), &found, &err, err.count)
                }
            }
            if n < 0 { throw Problem.failed("\(pkg.file): " + String(cString: err)) }
            for (k, f) in found.enumerated() where f != 0 { have.insert(spec.files[k]) }
            AVPLog.log("Preparar: \(pkg.file): \(n) librerías")
        }
        let missing = spec.files.filter { !have.contains($0) }
        guard missing.isEmpty else {
            throw Problem.failed(AVPL("Faltan librerías en los paquetes: ", "Libraries missing from the packages: ")
                                 + missing.joined(separator: ", "))
        }
        try want.write(to: stampURL, atomically: true, encoding: .utf8)
        try? fm.removeItem(at: debs)  // 30 MB not needed any more
        progress(1, AVPL("Listas", "Done"))
        return out
    }

    private static func download(_ url: String, to dest: URL) throws {
        guard let u = URL(string: url) else { throw Problem.failed("URL \(url)") }
        let sem = DispatchSemaphore(value: 0)
        final class Outcome: @unchecked Sendable { var error: Error? }
        let outcome = Outcome()
        let task = URLSession.shared.downloadTask(with: u) { tmp, response, error in
            defer { sem.signal() }
            if let error { outcome.error = error; return }
            guard let tmp, (response as? HTTPURLResponse)?.statusCode == 200 else {
                outcome.error = Problem.failed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0): \(url)")
                return
            }
            do { try FileManager.default.moveItem(at: tmp, to: dest) } catch { outcome.error = error }
        }
        task.resume()
        sem.wait()
        if let failure = outcome.error {
            throw Problem.failed(AVPL("No se pudo descargar \(dest.lastPathComponent): ", "Could not download \(dest.lastPathComponent): ")
                                 + failure.localizedDescription)
        }
    }

    static func sha256(of url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while true {
            let chunk = try autoreleasepool { try h.read(upToCount: 4 << 20) } ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: 2. Conversion

    struct Source { let url: URL; let stem: String }

    static func isELF(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        return (try? h.read(upToCount: 4)) == Data([0x7F, 0x45, 0x4C, 0x46])
    }

    /// Every ELF the runtime can load, symlinks left out (the runtime asks by stem, so one
    /// translation answers every name).
    static func sources(game: URL, runtime: URL) -> [Source] {
        let fm = FileManager.default
        var out: [Source] = []
        // Several files can share a stem (libavcodec.so and libavcodec.so.58.91.100): the largest is the real
        // library, the others are the depot's small copies of soname links.
        var best: [String: (url: URL, size: Int64, dir: Int)] = [:]
        var order: [String] = []
        for (d, dir) in [game.appendingPathComponent("bin/linuxsteamrtarm64"), game.appendingPathComponent("hlvr/bin/linuxsteamrtarm64"), runtime].enumerated() {
            let names = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
            for name in names where !name.hasPrefix(".") {
                let url = dir.appendingPathComponent(name)
                let attrs = try? fm.attributesOfItem(atPath: url.path)
                guard (attrs?[.type] as? FileAttributeType) == .typeRegular else { continue }
                guard name.contains(".so") || !name.contains("."), isELF(url) else { continue }
                let s = stem(name)
                let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                if let prev = best[s] {
                    // Only within one folder; across folders the first folder wins, as the loader's search order does.
                    if prev.dir == d, size > prev.size {
                        AVPLog.log("Preparar: \(s): se usa \(name) (\(size >> 10) KB) en vez de \(prev.url.lastPathComponent) (\(prev.size >> 10) KB)")
                        best[s] = (url, size, d)
                    }
                    continue
                }
                best[s] = (url, size, d)
                order.append(s)
            }
        }
        for s in order { if let b = best[s] { out.append(Source(url: b.url, stem: s)) } }
        return out
    }

    private static func sourceStamp(_ s: Source) -> String {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: s.url.path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let date = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(converterVersion)|\(s.url.lastPathComponent)|\(size)|\(Int64(date))"
    }

    private static func convert(game: URL, runtime: URL, cache: URL, progress: @escaping (Double, String) -> Void) throws -> URL {
        let fm = FileManager.default
        let dylibs = cache.appendingPathComponent("dylibs", isDirectory: true)
        try fm.createDirectory(at: dylibs, withIntermediateDirectories: true)
        let all = sources(game: game, runtime: runtime)
        guard all.contains(where: { $0.stem == "hlvr" }), all.count > 22 else {
            throw Problem.failed(AVPL("No se encuentran los binarios ARM64 de Linux del juego (bin/linuxsteamrtarm64).",
                                      "The game's Linux ARM64 binaries were not found (bin/linuxsteamrtarm64)."))
        }
        let t0 = Date()
        var converted = 0
        for (k, s) in all.enumerated() {
            let out = dylibs.appendingPathComponent(s.stem + ".dylib")
            let stampURL = dylibs.appendingPathComponent(s.stem + ".stamp")
            let want = sourceStamp(s)
            if (try? String(contentsOf: stampURL, encoding: .utf8)) == want, fm.fileExists(atPath: out.path) { continue }
            progress(Double(k) / Double(all.count), AVPL("Convirtiendo", "Converting") + " \(s.url.lastPathComponent) (\(k + 1)/\(all.count))")
            try? fm.removeItem(at: stampURL)
            var err = [CChar](repeating: 0, count: 512)
            let t = Date()
            let rc: Int32 = autoreleasepool { klepton_ld_run(s.url.path, out.path, &err, err.count) }
            if rc != 0 {
                throw Problem.failed("klepton-ld \(s.url.lastPathComponent): " + String(cString: err))
            }
            try want.write(to: stampURL, atomically: true, encoding: .utf8)
            converted += 1
            let mb = ((try? fm.attributesOfItem(atPath: out.path)[.size] as? NSNumber)?.int64Value ?? 0) >> 20
            AVPLog.log("Preparar: \(s.url.lastPathComponent) -> \(out.lastPathComponent) (\(mb) MB, \(String(format: "%.1f", Date().timeIntervalSince(t))) s)")
        }
        // Translations whose source is gone (a game update dropped a library).
        let stems = Set(all.map(\.stem))
        for f in (try? fm.contentsOfDirectory(atPath: dylibs.path)) ?? [] where f.hasSuffix(".dylib") || f.hasSuffix(".stamp") {
            if !stems.contains((f as NSString).deletingPathExtension) { try? fm.removeItem(at: dylibs.appendingPathComponent(f)) }
        }
        AVPLog.log("Preparar: \(all.count) librerías, \(converted) convertidas ahora (\(Int(Date().timeIntervalSince(t0))) s)")
        progress(1, AVPL("Convertidas", "Converted"))
        return dylibs
    }

    // MARK: 3. Signing

    private static func sign(_ dylibs: URL, identity: AVPSigner.Identity, progress: @escaping (Double, String) -> Void) throws -> URL {
        let fm = FileManager.default
        let folder = AVPFolder.signed
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let fingerprint = AVPSigner.fingerprint(identity)
        let libs = ((try? fm.contentsOfDirectory(at: dylibs, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "dylib" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        if libs.isEmpty { throw Problem.failed(AVPL("La conversión no dejó librerías.", "The conversion left no libraries.")) }
        // A different certificate: every copy is redone.
        let certURL = folder.appendingPathComponent(".certificate")
        if (try? String(contentsOf: certURL, encoding: .utf8)) != fingerprint {
            AVPLog.log("Preparar: certificado nuevo (\(fingerprint)): se firman todas")
            try? fm.removeItem(at: folder)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try fingerprint.write(to: certURL, atomically: true, encoding: .utf8)
        }
        var variants = AVPSigner.variants()
        var chosen: AVPSigner.Variant?
        var signedNow = 0
        for (k, lib) in libs.enumerated() {
            let name = lib.lastPathComponent
            let out = folder.appendingPathComponent(name)
            let sigURL = folder.appendingPathComponent(name + ".sig")
            let conv = (try? String(contentsOf: dylibs.appendingPathComponent((name as NSString).deletingPathExtension + ".stamp"),
                                    encoding: .utf8)) ?? "?"
            let want = conv + "|" + fingerprint
            if (try? String(contentsOf: sigURL, encoding: .utf8)) == want, fm.fileExists(atPath: out.path) { continue }
            progress(Double(k) / Double(libs.count), AVPL("Firmando", "Signing") + " \(name)")
            while true {
                let partial = out.appendingPathExtension("partial")
                try? fm.removeItem(at: partial)
                try fm.copyItem(at: lib, to: partial)
                let variant = chosen ?? variants[0]
                do {
                    try AVPSigner.sign(path: partial.path, variant: variant, identity: identity)
                } catch {
                    try? fm.removeItem(at: partial)
                    throw Problem.failed("\(name): \(error.localizedDescription)")
                }
                try? fm.removeItem(at: out)
                try fm.moveItem(at: partial, to: out)
                if chosen != nil { break }
                if let h = dlopen(out.path, RTLD_NOW | RTLD_LOCAL) {
                    _ = h  // left open: the runtime dlopens the same path later
                    chosen = variant
                    AVPSigner.remember(variant)
                    AVPLog.log("Preparar: el sistema acepta la firma \(variant.name) (\(name))")
                    break
                }
                let reason = dlerror().map { String(cString: $0) } ?? "?"
                AVPLog.log("Preparar: dlopen rechazó la firma \(variant.name): \(reason)")
                variants.removeFirst()
                if variants.isEmpty || !reason.contains("signature") {
                    try? fm.removeItem(at: out)
                    throw Problem.failed(AVPL("El sistema no acepta la librería firmada: ", "The system refuses the signed library: ") + reason)
                }
            }
            try want.write(to: sigURL, atomically: true, encoding: .utf8)
            signedNow += 1
        }
        AVPLog.log("Preparar: \(libs.count) librerías firmadas (\(signedNow) ahora) en \(folder.path)")
        progress(1, AVPL("Firmadas", "Signed"))
        return folder
    }

    // MARK: 4. Pipelines

    private static func pipelines(game: URL, cache: URL, progress: @escaping (Double, String) -> Void) throws -> URL {
        let fm = FileManager.default
        let out = cache.appendingPathComponent("pipelines.foz")
        let stampURL = cache.appendingPathComponent("pipelines.stamp")
        guard let recipe = Bundle.main.url(forResource: "alyx", withExtension: "recipe") else {
            throw Problem.failed(AVPL("Falta alyx.recipe en la app.", "alyx.recipe is missing from the app."))
        }
        func fileID(_ u: URL) -> String {
            let a = (try? fm.attributesOfItem(atPath: u.path)) ?? [:]
            return "\((a[.size] as? NSNumber)?.int64Value ?? 0)/\(Int64((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0))"
        }
        let want = [pipelinesVersion, fileID(recipe), fileID(game.appendingPathComponent("core/shaders_vulkan_dir.vpk")),
                    fileID(game.appendingPathComponent("hlvr/shaders_vulkan_dir.vpk"))].joined(separator: "|")
        if (try? String(contentsOf: stampURL, encoding: .utf8)) == want, fm.fileExists(atPath: out.path) {
            progress(1, AVPL("Ya lista", "Already done"))
            return out
        }
        try? fm.removeItem(at: stampURL)
        progress(0, AVPL("Leyendo los shaders del juego", "Reading the game's shaders"))
        let box = ProgressBox(progress)
        let ctx = Unmanaged.passRetained(box)
        defer { ctx.release() }
        var err = [CChar](repeating: 0, count: 512)
        let t0 = Date()
        let n = avp_pipelines_build(recipe.path, game.path, out.path, { done, total, user in
            guard let user else { return }
            let b = Unmanaged<ProgressBox>.fromOpaque(user).takeUnretainedValue()
            b.report(total > 0 ? Double(done) / Double(total) : 0,
                     AVPL("Shaders del juego \(done) / \(total)", "Game shaders \(done) / \(total)"))
        }, ctx.toOpaque(), &err, err.count)
        guard n >= 0 else {
            throw Problem.failed(AVPL("Lista de pipelines: ", "Pipeline list: ") + String(cString: err))
        }
        try want.write(to: stampURL, atomically: true, encoding: .utf8)
        AVPLog.log("Preparar: pipelines.foz con \(n) shaders en \(Int(Date().timeIntervalSince(t0))) s")
        progress(1, AVPL("Lista", "Done"))
        return out
    }

    private final class ProgressBox {
        let report: (Double, String) -> Void
        init(_ r: @escaping (Double, String) -> Void) { report = r }
    }
}
