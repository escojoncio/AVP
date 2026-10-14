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
        // VPKEngine's caches already hold every pipeline for this VPVulkan build and this list (a full prewarm
        // filled them, AVPPipelineCache): the game's device loads them itself (gpu.prewarm in the boot log).
        let cache = AVPPipelineCache.current
        if let cache, cache.warm {
            AVPLog.log("Preparar: caché de pipelines de VPKEngine ya completa (\(cache.summary)); precompilado saltado")
            progress(4, 1, AVPL("Shaders listos (caché)", "Shaders ready (cache)"))
            return
        }
        if let cache { AVPPipelineCache.clearWarm(cache) }
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
            if p.total > 0 && p.done >= p.total {
                // Replay done: VPKEngine is compiling the queued shaders into the system's shader cache. Seconds with
                // a warm cache; minutes once after an update that changed the shader translator.
                let s = Int(Date().timeIntervalSince(t0))
                progress(4, 0.99, AVPL("Compilando shaders en la GPU… \(s) s — no cierres la app (tras una actualización puede tardar unos minutos, solo una vez)",
                                       "Compiling shaders on the GPU… \(s) s — keep the app open (after an update this can take a few minutes, once)"))
            } else {
                progress(4, f, AVPL("Shaders \(p.done) / \(p.total)", "Shaders \(p.done) / \(p.total)"))
            }
        }
        let p = AlyxBoot.pipelineProgress()
        progress(4, 1, AVPL("Shaders listos", "Shaders ready"))
        // Warm only when the prewarm ran to the end on every thread it was given (rc 0) and the runtime waited for
        // the driver's queued compiles ("[foz] prewarm: waited" in klepton-prewarm-*.log).
        if let cache, rc == 0, unfinished == 0, p.total > 0 { AVPPipelineCache.markWarm(cache) }
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

    /// *.foz files at the root of the AVP folder -> <data>/klfz/user-<name> (copied when size or date changed; removed
    /// there when gone from the folder). Returns "<name>:<size>/<mtime>" per file, for the stamp.
    static func importExtraFoz(root: URL) -> [String] {
        let fm = FileManager.default
        let klfz = AVPFolder.data.appendingPathComponent("klfz", isDirectory: true)
        try? fm.createDirectory(at: klfz, withIntermediateDirectories: true)
        var ids: [String] = []
        var keep = Set<String>()
        let names = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).filter { $0.lowercased().hasSuffix(".foz") }.sorted()
        for name in names {
            let src = root.appendingPathComponent(name)
            let a = (try? fm.attributesOfItem(atPath: src.path)) ?? [:]
            let size = (a[.size] as? NSNumber)?.int64Value ?? 0
            let mtime = Int64((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
            guard size > 0 else { continue }
            let id = "\(name):\(size)/\(mtime)"
            ids.append(id)
            let dstName = "user-" + (name as NSString).deletingPathExtension + ".foz"   // the replay matches ".foz" exactly
            keep.insert(dstName)
            let dst = klfz.appendingPathComponent(dstName)
            let idURL = klfz.appendingPathComponent(dstName + ".id")
            if (try? String(contentsOf: idURL, encoding: .utf8)) == id, fm.fileExists(atPath: dst.path) { continue }
            do {
                try? fm.removeItem(at: dst)
                try fm.copyItem(at: src, to: dst)
                try id.write(to: idURL, atomically: true, encoding: .utf8)
                AVPLog.log("Preparar: base de pipelines del usuario \(name) (\(size / 1_048_576) MB) copiada a klfz: se precompila")
            } catch {
                AVPLog.log("Preparar: no se pudo copiar \(name) a klfz: \(error.localizedDescription)")
            }
        }
        for f in (try? fm.contentsOfDirectory(atPath: klfz.path)) ?? [] where f.hasPrefix("user-") {
            let base = f.hasSuffix(".id") ? String(f.dropLast(3)) : f
            if !keep.contains(base) { try? fm.removeItem(at: klfz.appendingPathComponent(f)) }
        }
        return ids
    }

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
        // The recipe ships in the app bundle, whose files get a new date at every install: by content, so a
        // reinstall of the same build does not rebuild the list (13 s). The game's packs keep size/date (GBs).
        func contentID(_ u: URL) -> String {
            guard let d = try? Data(contentsOf: u, options: .mappedIfSafe) else { return fileID(u) }
            return "sha256:" + SHA256.hash(data: d).prefix(12).map { String(format: "%02x", $0) }.joined()
        }
        // Build 41: extra Fossilize databases the user drops into the AVP folder (Steam's own collection for the
        // game, steamapps/shadercache/546560/fozpipelinesv6/steamapp_pipeline_cache.foz: every pipeline Steam users
        // ever recorded, driver-independent) are copied into <data>/klfz, which both the prewarm and the game replay.
        // Their identity joins the stamp so the prewarm runs again once when one is added or changed.
        let extra = importExtraFoz(root: cache.deletingLastPathComponent())
        let want = [pipelinesVersion, contentID(recipe), fileID(game.appendingPathComponent("core/shaders_vulkan_dir.vpk")),
                    fileID(game.appendingPathComponent("hlvr/shaders_vulkan_dir.vpk"))].joined(separator: "|")
            + (extra.isEmpty ? "" : "|extra " + extra.joined(separator: ","))
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

// MARK: VPKEngine's persistent pipeline caches

/// <data>/vpcache is VP_PIPELINE_CACHE_DIR: VPKEngine's recipes (recipes.bin: each pipeline's SPIR-V inputs and
/// translated MSL) and Metal binary archives (pipelines-<n>.metalar + pipelines.count). warm.stamp records that a
/// full prewarm (every database replayed and the driver's queued compiles waited for) filled them for this
/// VPVulkan build and this pipeline list. archive.inflight is VPKEngine's own (0017): it exists while its binary
/// archive code runs, so finding it at start means the last run died inside it; two runs in a row -> archive.off
/// (VP_PIPELINE_ARCHIVE=0 for good, the recipes stay).
enum AVPPipelineCache {
    struct State {
        let dir: URL
        let key: String
        let warm: Bool
        let archiveOff: Bool
        let summary: String
    }
    /// Decided at writeConfig (before the prewarm), read by AVPPrepare.prewarm.
    nonisolated(unsafe) static var current: State?

    static func configure(data: URL, pipelines: URL, engine: String, engineSignature: String = "") -> State {
        let fm = FileManager.default
        let dir = data.appendingPathComponent("vpcache", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = dir.appendingPathComponent("warm.stamp")
        // Metal binary archives are off for good: opening one cost ~30x its file size in memory (build 14:
        // pipelines-4.metalar, 95 MB on disk -> +4.4 GB), and saving them re-compiles every pipeline serially
        // (minutes). The OS shader cache keeps compiled shaders between launches by itself. Old files are removed.
        let archiveOff = true
        for f in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        where f.hasSuffix(".metalar") || f == "pipelines.count" || f.hasPrefix("archive.") {
            try? fm.removeItem(at: dir.appendingPathComponent(f))
        }
        let driver = AVPLaunch.driverPath.flatMap { digest($0) } ?? "?"
        let list = (try? String(contentsOf: pipelines.deletingLastPathComponent().appendingPathComponent("pipelines.stamp"),
                                encoding: .utf8)) ?? "?"
        // The OS version too: Metal binary archives and the system's shader cache are only valid for the OS (and GPU
        // driver) that wrote them.
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let key = "avp-vpcache-2|vpvulkan \(driver)|list \(list)|os \(os)|archive \(archiveOff ? "off" : "on")"
        // The previous boot log is judged only if that session ran with this same key (last.key, written below for
        // the session about to start): after a new driver, list or OS its misses say nothing about this cache.
        let lastKeyURL = dir.appendingPathComponent("last.key")
        if (try? String(contentsOf: lastKeyURL, encoding: .utf8)) == key {
            checkGameMisses(dir: dir, key: key, bootLog: AVPLog.directory.appendingPathComponent("klepton-boot-\(engine).log"))
        }
        try? key.write(to: lastKeyURL, atomically: true, encoding: .utf8)
        summarizeGpuTrouble(dir: dir, bootLog: AVPLog.directory.appendingPathComponent("klepton-boot-\(engine).log"))
        // Build 15's quarantine and suspects came from timestamp-only blame (passes with no draws read as stuck):
        // not proof, so they are dropped once (VPKEngine 0020 quarantines only on Metal's own verdict).
        let qv2 = dir.appendingPathComponent("quarantine.v2")
        if !fm.fileExists(atPath: qv2.path) {
            try? fm.removeItem(at: dir.appendingPathComponent("quarantine.txt"))
            try? fm.removeItem(at: dir.appendingPathComponent("suspects.txt"))
            fm.createFile(atPath: qv2.path, contents: nil)
        }
        // Build 16: the hangs came from a Metal resolve of the game's 1x depth (VPKEngine 0021 copies instead), not
        // from motion vectors (they went on after motion.off) nor from the passes Metal called "affected" (victims):
        // everything blamed until now is dropped once, motion vectors come back.
        let qv3 = dir.appendingPathComponent("quarantine.v3")
        if !fm.fileExists(atPath: qv3.path) {
            try? fm.removeItem(at: dir.appendingPathComponent("quarantine.txt"))
            try? fm.removeItem(at: dir.appendingPathComponent("suspects.txt"))
            try? fm.removeItem(at: dir.appendingPathComponent("motion.off"))
            fm.createFile(atPath: qv3.path, contents: nil)
            AVPLog.log("Gráficos: cuarentena, sospechosos y motion.off de builds anteriores borrados (una vez)")
        }
        if fm.fileExists(atPath: dir.appendingPathComponent("motion.off").path) {
            AVPLog.log("Gráficos: vectores de movimiento de VPKTAA desactivados tras un cuelgue de GPU (motion.off)")
        }
        // Build 30: the quarantine and the single-hang suspects are only valid for the engine configuration that
        // produced them (VPVulkan build + the toggles that change translation and encoding, from AVPSettings). Logs
        // 20/21: pipelines that faulted under VPVK_AMPLIFY=1 stayed quarantined with it off, together with a compute
        // pipeline the hunter blamed after that fault (the light binning: black scene, only the HUD drawn). Another
        // signature, or none recorded yet: both files are dropped and the new signature recorded.
        let qkeyURL = dir.appendingPathComponent("quarantine.key")
        let qkey = "\(driver)|\(engineSignature)"
        let oldKey = try? String(contentsOf: qkeyURL, encoding: .utf8)
        if oldKey != qkey {
            let had = quarantineCount(dir: dir)
            try? fm.removeItem(at: dir.appendingPathComponent("quarantine.txt"))
            try? fm.removeItem(at: dir.appendingPathComponent("suspects.txt"))
            try? qkey.write(to: qkeyURL, atomically: true, encoding: .utf8)
            if had > 0 || oldKey != nil {
                AVPLog.log("Gráficos: cuarentena de otra configuración del motor descartada (\(had) pipelines; "
                           + (oldKey == nil ? "sin firma previa" : "firma anterior \(oldKey!)") + "; ahora \(qkey))")
            }
        }
        let quarantined = quarantineCount(dir: dir)
        if quarantined > 0 {
            AVPLog.log("Gráficos: \(quarantined) pipelines en cuarentena (VPKEngine no los dibuja; Ajustes › Diagnóstico › "
                       + "Restablecer shaders en cuarentena)")
        }
        let recipes = (try? fm.attributesOfItem(atPath: dir.appendingPathComponent("recipes.bin").path))?[.size] as? NSNumber
        let archiveFiles = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".metalar") }
        let archives = archiveFiles.count
        // Their size on disk: VPKEngine opens them only within a memory budget (0019: gpu.pso.cache open/skipped).
        let archiveMB = archiveFiles.reduce(Int64(0)) { sum, name in
            sum + (((try? fm.attributesOfItem(atPath: dir.appendingPathComponent(name).path))?[.size] as? NSNumber)?.int64Value ?? 0)
        } / 1_048_576
        // Without the binary archive the game would compile every pipeline again: never warm then (it replays).
        let warm = driver != "?" && list != "?" && (recipes?.int64Value ?? 0) > 0 && !archiveOff && archives > 0
            && (try? String(contentsOf: stamp, encoding: .utf8)) == key
        let summary = "recetas \((recipes?.int64Value ?? 0) / 1_048_576) MB, \(archives) archivo(s) binario(s) (\(archiveMB) MB)"
            + (archiveOff ? " (desactivados)" : "") + ", VPVulkan \(driver), \(os)"
        let verdict = warm ? "completa"
            : archiveOff ? "sin archivo binario: precompilado y replay del juego en cada arranque"
            : "por llenar (precompilado completo antes de jugar)"
        AVPLog.log("Gráficos: caché de pipelines \(dir.lastPathComponent): \(summary); \(verdict)")
        let s = State(dir: dir, key: key, warm: warm, archiveOff: archiveOff, summary: summary)
        current = s
        return s
    }

    // MARK: Quarantine (VPKEngine 0018: <VP_PIPELINE_CACHE_DIR>/quarantine.txt, pipelines that hung the GPU)

    static var cacheDir: URL { AVPFolder.data.appendingPathComponent("vpcache", isDirectory: true) }
    static func quarantineURL(dir: URL = cacheDir) -> URL { dir.appendingPathComponent("quarantine.txt") }

    /// Entries in quarantine.txt: one per non-empty line that is not a comment.
    static func quarantineCount(dir: URL = cacheDir) -> Int {
        guard let text = try? String(contentsOf: quarantineURL(dir: dir), encoding: .utf8) else { return 0 }
        return text.split(whereSeparator: \.isNewline).filter {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return !t.isEmpty && !t.hasPrefix("#")
        }.count
    }

    /// Settings › Diagnóstico: forget the quarantine (VPKEngine draws those pipelines again next launch).
    static func resetQuarantine() {
        let n = quarantineCount()
        let url = quarantineURL()
        // Single-hang suspects go too: a reset is a clean slate, not "persist on the next hang".
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent().appendingPathComponent("suspects.txt"))
        // And VPKTAA's motion vectors, turned off after a GPU hang (VPKEngine 0020): they come back next launch.
        let motionOff = url.deletingLastPathComponent().appendingPathComponent("motion.off")
        if FileManager.default.fileExists(atPath: motionOff.path) {
            try? FileManager.default.removeItem(at: motionOff)
            AVPLog.log("Gráficos: vectores de movimiento de VPKTAA reactivados (se aplican en el próximo arranque)")
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            AVPLog.log("Gráficos: no hay shaders en cuarentena que restablecer")
            return
        }
        do {
            try FileManager.default.removeItem(at: url)
            AVPLog.log("Gráficos: cuarentena restablecida (\(n) pipelines); VPKEngine los vuelve a dibujar en el próximo arranque")
        } catch {
            AVPLog.log("Gráficos: no se pudo borrar \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// The previous session's GPU hangs and quarantines (VPKEngine 0018 logs gpu.hang.stuck / gpu.quarantine in the
    /// boot log), summarised in app.txt once per boot log (gpu-trouble.seen holds the date of the one reported).
    private static func summarizeGpuTrouble(dir: URL, bootLog: URL) {
        let fm = FileManager.default
        guard let date = (try? fm.attributesOfItem(atPath: bootLog.path))?[.modificationDate] as? Date else { return }
        let stamp = String(Int64(date.timeIntervalSince1970))
        let seenURL = dir.appendingPathComponent("gpu-trouble.seen")
        if (try? String(contentsOf: seenURL, encoding: .utf8)) == stamp { return }
        try? stamp.write(to: seenURL, atomically: true, encoding: .utf8)
        guard let h = try? FileHandle(forReadingFrom: bootLog) else { return }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 8_388_608 ? size - 8_388_608 : 0)
        guard let data = try? h.readToEnd(),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return }
        var hangs: [String] = [], quarantines: [String] = [], hunt: [String] = []
        var hangCount = 0
        for line in text.split(whereSeparator: \.isNewline) {
            if line.contains("kIOGPUCommandBufferCallbackErrorHang") { hangCount += 1 }
            // The hang hunter's verdicts and the 1x-resolve guards (VPKEngine 0021).
            for tag in ["gpu.hunt verdict", "gpu.hunt culprit", "gpu.hunt start", "what=resolve_refused", "vk.resolve dropped"]
            where line.contains(tag) {
                if let r = line.range(of: tag) { hunt.append(String(line[r.lowerBound...].prefix(220))) }
            }
            guard line.contains("gpu.hang.stuck") || line.contains("gpu.quarantine") else { continue }
            // From the tag on (the boot log prefixes some lines with a timestamp and process).
            let tag = line.contains("gpu.hang.stuck") ? "gpu.hang.stuck" : "gpu.quarantine"
            guard let r = line.range(of: tag) else { continue }
            let entry = String(line[r.lowerBound...].prefix(200))
            if tag == "gpu.hang.stuck" { hangs.append(entry) } else { quarantines.append(entry) }
        }
        guard hangCount > 0 || !hangs.isEmpty || !quarantines.isEmpty || !hunt.isEmpty else {
            AVPLog.log("Gráficos: la sesión anterior no tuvo ningún cuelgue de GPU")
            return
        }
        AVPLog.log("Gráficos: la sesión anterior tuvo \(hangCount) cuelgue(s) de GPU, \(hangs.count) bloqueo(s) señalados "
                   + "(gpu.hang.stuck) y \(quarantines.count) aviso(s) de cuarentena (gpu.quarantine)")
        for e in hunt.prefix(12) { AVPLog.log("  \(e)") }
        func firstDistinct(_ lines: [String]) -> [String] {
            var seen = Set<String>()
            return Array(lines.filter { seen.insert($0).inserted }.prefix(3))
        }
        for e in firstDistinct(hangs) + firstDistinct(quarantines) { AVPLog.log("  \(e)") }
    }

    static func markWarm(_ s: State) {
        guard !s.archiveOff else { return }   // the C side reports such a prewarm as incomplete (rc 1) anyway
        try? s.key.write(to: s.dir.appendingPathComponent("warm.stamp"), atomically: true, encoding: .utf8)
        AVPLog.log("Preparar: caché de pipelines de VPKEngine completa; el juego no repite el replay")
    }

    static func clearWarm(_ s: State) {
        try? FileManager.default.removeItem(at: s.dir.appendingPathComponent("warm.stamp"))
    }

    /// SHA-256 (first 12 bytes, hex) of the VPVulkan binary: a new driver build invalidates the stamp.
    private static func digest(_ path: String) -> String? {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) else { return nil }
        return SHA256.hash(data: d).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// archive.inflight left by the last run (it died inside VPKEngine's binary archive code: open, add, save or a
    /// lookup, Apple's <redacted> frames included). One strike can be the system closing the app at that moment;
    /// two in a row turn the archive off. A run that leaves no marker clears the strikes.
    private static func checkArchiveInflight(dir: URL) {
        let fm = FileManager.default
        let inflight = dir.appendingPathComponent("archive.inflight")
        let strikesURL = dir.appendingPathComponent("archive.strikes")
        guard fm.fileExists(atPath: inflight.path) else {
            try? fm.removeItem(at: strikesURL)
            return
        }
        let what = ((try? String(contentsOf: inflight, encoding: .utf8)) ?? "?").trimmingCharacters(in: .whitespacesAndNewlines)
        try? fm.removeItem(at: inflight)
        let strikes = (Int((try? String(contentsOf: strikesURL, encoding: .utf8)) ?? "") ?? 0) + 1
        try? String(strikes).write(to: strikesURL, atomically: true, encoding: .utf8)
        if strikes >= 2 {
            try? "inflight \(what), \(strikes) runs".write(to: dir.appendingPathComponent("archive.off"), atomically: true, encoding: .utf8)
            try? fm.removeItem(at: dir.appendingPathComponent("warm.stamp"))
            AVPLog.log("Gráficos: el archivo binario de pipelines de VPKEngine quedó a medias (\(what)) \(strikes) veces seguidas; "
                       + "queda desactivado (VP_PIPELINE_ARCHIVE=0), las recetas siguen")
        } else {
            AVPLog.log("Gráficos: la última sesión terminó dentro del archivo binario de pipelines (\(what)); "
                       + "si se repite, se desactiva")
        }
    }

    /// The last boot log, from a run that skipped the game's replay: if the game's own pipeline creates mostly missed
    /// what VPKEngine's prewarm compiled ("gpu.pso.recipe game hits=H misses=M"), the cache was not as complete as
    /// warm.stamp said: the stamp goes, so the next start replays everything again. Once per key (miss.reject): misses
    /// that a full replay does not fix are pipelines absent from the lists, which replaying again would not help.
    private static func checkGameMisses(dir: URL, key: String, bootLog: URL) {
        guard let h = try? FileHandle(forReadingFrom: bootLog) else { return }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 8_388_608 ? size - 8_388_608 : 0)
        guard let data = try? h.readToEnd(), let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return }
        guard text.contains("[foz] game replay skipped") else { return }
        guard let line = text.components(separatedBy: "\n").last(where: { $0.contains("gpu.pso.recipe game hits=") }) else { return }
        func value(_ name: String) -> Int {
            guard let r = line.range(of: name + "=") else { return 0 }
            return Int(line[r.upperBound...].prefix { $0.isNumber }) ?? 0
        }
        let hits = value("hits"), misses = value("misses")
        guard hits + misses >= 64, misses * 4 > hits + misses else { return }
        let reject = dir.appendingPathComponent("miss.reject")
        if (try? String(contentsOf: reject, encoding: .utf8)) == key {
            AVPLog.log("Gráficos: el juego creó \(misses) de \(hits + misses) pipelines fuera de la caché, también tras un "
                       + "precompilado completo: son pipelines que no están en las listas (se graban para la próxima vez)")
            return
        }
        try? key.write(to: reject, atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("warm.stamp"))
        AVPLog.log("Gráficos: el juego creó \(misses) de \(hits + misses) pipelines fuera de la caché de VPKEngine; "
                   + "se descarta warm.stamp y el próximo arranque precompila todo otra vez")
    }
}
