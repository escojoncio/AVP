// AVP: the AVP folder. Made once by the player (Files app, "On My Apple Vision Pro"), outside the
// app so the game, the conversions and the logs survive deleting or reinstalling the app:
//
//   AVP/game/      the depot's game/ folder (bin/, core/, hlvr/); saves live in game/hlvr/SAVE,
//                  where Steam Cloud puts them
//   AVP/Cache/     what the app made on the headset: dylibs/ (converted, unsigned), runtime/
//                  (Debian libraries), debs/, pipelines.foz, stamps
//   AVP/Logs/      copies of the app's logs
//
// The signed copies the game loads live inside the app (Library/Application Support/AVP/Signed,
// AVPPrepare). The app keeps a bookmark to the folder (settings and keychain, which outlives a
// reinstall), the same scheme as VisionQuestPro's QUEST folder.

import Foundation
import Security

final class AVPFolder: @unchecked Sendable {
    static let shared = AVPFolder()

    static let folderName = "AVP"
    static let gameName = "game"
    static let cacheName = "Cache"
    static let logsName = "Logs"

    /// Room the preparation needs on top of the download: converted + signed libraries,
    /// runtime packages, the pipeline list and the shader archives (~8 GB), plus a 2 GB margin.
    static let workingBytes: UInt64 = 8_000_000_000
    static let marginBytes: UInt64 = 2_000_000_000

    private static let defaultsKey = "avp.folderBookmark"
    private static let keychainService = "avp.folder"
    private static let keychainAccount = "folder-bookmark"

    private let lock = NSLock()
    private var opened: URL?

    private init() {}

    /// The folder, opened for this process (nil: not chosen yet, or the bookmark no longer opens).
    var url: URL? {
        lock.lock(); defer { lock.unlock() }
        if let opened { return opened }
        let stored: [(String, Data?)] = [("defaults", UserDefaults.standard.data(forKey: Self.defaultsKey)),
                                         ("keychain", Self.keychainBookmark())]
        for (source, data) in stored {
            guard let data else { continue }
            var stale = false
            guard let resolved = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
                AVPLog.log("AVP: el marcador guardado en \(source) ya no abre")
                continue
            }
            let accessing = resolved.startAccessingSecurityScopedResource()
            guard accessing || FileManager.default.isReadableFile(atPath: resolved.path) else {
                AVPLog.log("AVP: sin acceso a \(resolved.path) (\(source))")
                continue
            }
            if stale || source != "defaults",
               let fresh = try? resolved.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                Self.save(fresh)
            }
            opened = resolved
            Self.makeSubfolders(resolved)
            AVPLog.log("AVP: \(resolved.path) (\(source))")
            return resolved
        }
        return nil
    }

    /// The folder the player picked. Nil, or why it cannot be used.
    func choose(_ picked: URL) -> String? {
        guard picked.lastPathComponent.caseInsensitiveCompare(Self.folderName) == .orderedSame else {
            return AVPL("Esa carpeta se llama «\(picked.lastPathComponent)». Elige la carpeta llamada AVP.",
                        "That folder is called “\(picked.lastPathComponent)”. Choose the folder called AVP.")
        }
        let accessing = picked.startAccessingSecurityScopedResource()
        guard accessing || FileManager.default.isReadableFile(atPath: picked.path) else {
            return AVPL("No se pudo abrir la carpeta AVP.", "The AVP folder could not be opened.")
        }
        guard let data = try? picked.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else {
            if accessing { picked.stopAccessingSecurityScopedResource() }
            return AVPL("No se pudo recordar la carpeta AVP.", "The AVP folder could not be remembered.")
        }
        Self.save(data)
        lock.lock()
        opened?.stopAccessingSecurityScopedResource()
        opened = picked
        lock.unlock()
        Self.makeSubfolders(picked)
        AVPLog.log("AVP: elegida \(picked.path)")
        return nil
    }

    func forget() {
        lock.lock()
        opened?.stopAccessingSecurityScopedResource()
        opened = nil
        lock.unlock()
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
        SecItemDelete(Self.keychainQuery() as CFDictionary)
        AVPLog.log("AVP: olvidada")
    }

    var game: URL? { sub(Self.gameName) }
    var cache: URL? { sub(Self.cacheName) }
    var logs: URL? { sub(Self.logsName) }

    /// The app-internal folder with the signed copies of the converted libraries.
    static var signed: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AVP/Signed", isDirectory: true)
    }

    /// Writable data the runtime keeps between launches (recorded pipelines, klfz/).
    static var data: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AVP/Data", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// The config files written on every launch (alyx-env.txt, convars, video2.txt, fidelity table).
    static var config: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AVP/Config", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// Free bytes on the folder's volume (what the system would let an important download use).
    var freeSpace: UInt64? {
        guard let url else { return nil }
        let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage.map { UInt64(max(0, $0)) }
    }

    /// Nil when `downloadBytes` (still to fetch) plus the working space fit, else what is missing.
    func spaceProblem(downloadBytes: UInt64) -> String? {
        guard let free = freeSpace else { return nil }
        let need = downloadBytes + Self.workingBytes + Self.marginBytes
        guard free < need else { return nil }
        return AVPL("Falta espacio: hacen falta \(AVPLog.bytes(need)) (descarga + preparación + margen) y hay \(AVPLog.bytes(free)) libres.",
                    "Not enough space: \(AVPLog.bytes(need)) is needed (download + preparation + margin) and \(AVPLog.bytes(free)) is free.")
    }

    private func sub(_ name: String) -> URL? {
        guard let folder = url?.appendingPathComponent(name, isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func makeSubfolders(_ root: URL) {
        for name in [gameName, cacheName, logsName] {
            try? FileManager.default.createDirectory(at: root.appendingPathComponent(name, isDirectory: true),
                                                     withIntermediateDirectories: true)
        }
    }

    private static func save(_ bookmark: Data) {
        UserDefaults.standard.set(bookmark, forKey: defaultsKey)
        SecItemDelete(keychainQuery() as CFDictionary)
        var item = keychainQuery()
        item[kSecValueData as String] = bookmark
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }

    private static func keychainBookmark() -> Data? {
        var query = keychainQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func keychainQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: keychainService,
         kSecAttrAccount as String: keychainAccount]
    }
}
