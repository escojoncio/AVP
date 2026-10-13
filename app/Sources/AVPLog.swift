// AVP: the app's own log. Every diagnostic goes here (and to the system log): there is no Mac to
// attach. Written to Documents/Logs Alyx/app.txt and mirrored into AVP/Logs Alyx when the folder is chosen;
// the guest's logs (klepton-boot.log, klepton-crash.log, alyx-error.txt) go to the same folder. Shared from the app.

import Foundation

enum AVPLog {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handle: FileHandle?

    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs Alyx", isDirectory: true)
    }
    static var appLog: URL { directory.appendingPathComponent("app.txt") }
    static var previousLog: URL { directory.appendingPathComponent("app-previous.txt") }
    // The guest's logs go to the same folder (kl_app.c, KL_ALYX_LOG_DIR set by AVPLaunch), apart from
    // VisionQuestPro's, which shares this container (same bundle id).
    static var bootLog: URL { directory.appendingPathComponent("klepton-boot.log") }
    static var crashLog: URL { directory.appendingPathComponent("klepton-crash.log") }
    static var errorLog: URL { directory.appendingPathComponent("alyx-error.txt") }
    static var prewarmLog: URL { AVPFolder.data.appendingPathComponent("klfz/prewarm.log") }
    /// Every distinct Vulkan feature the game uses (kl_vk_census.inc), for VPKEngine.
    static var censusLog: URL { directory.appendingPathComponent("census.txt") }
    /// The game's own console (Msg output, our AVPFORCE lines from alyx-convars.lua).
    static var consoleLog: URL? { AVPFolder.shared.game?.appendingPathComponent("hlvr/console.log") }
    /// One boot/crash log per graphics engine (kl_app.c, KL_LOG_TAG), plus each one's previous run.
    static var engineLogs: [URL] {
        ["vpkengine", "moltenvk"].flatMap { e in
            ["klepton-boot-\(e).log", "klepton-boot-\(e).prev.log", "klepton-crash-\(e).log"].map { directory.appendingPathComponent($0) }
        }
    }
    private static var all: [URL] { [appLog, previousLog, bootLog, crashLog, errorLog, prewarmLog, censusLog] + engineLogs + (consoleLog.map { [$0] } ?? []) }

    /// Starts a new log for this session (the previous one is kept as app-previous.txt).
    static func start() {
        lock.lock(); defer { lock.unlock() }
        guard handle == nil else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Before any kl_app_configure_alyx (prewarm or Play): the guest's logs land here too.
        setenv("KL_ALYX_LOG_DIR", directory.path, 1)
        try? FileManager.default.removeItem(at: previousLog)
        try? FileManager.default.moveItem(at: appLog, to: previousLog)
        for old in captures { try? FileManager.default.removeItem(at: old) }
        // Logs of earlier builds' names (untagged, and the engine's old name): they only confuse a shared folder.
        for name in ["klepton-boot.log", "klepton-boot.prev.log", "klepton-crash.log", "klepton-boot-vpengine.log",
                     "klepton-boot-vpengine.prev.log", "klepton-crash-vpengine.log"] {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        FileManager.default.createFile(atPath: appLog.path, contents: nil)
        handle = try? FileHandle(forWritingTo: appLog)
        let info = Bundle.main.infoDictionary ?? [:]
        let line = "AVP \(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?")), "
            + "visionOS \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
        handle?.write(Data(line.utf8))
    }

    static func log(_ message: String) {
        NSLog("[avp] %@", message)
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withTime, .withColonSeparatorInTime])
        lock.lock(); defer { lock.unlock() }
        handle?.write(Data("\(stamp) \(message)\n".utf8))
    }

    /// Copies this session's logs into AVP/Logs (survives a reinstall; visible in Files).
    static func mirrorToFolder() {
        guard let dir = AVPFolder.shared.logs else { return }
        for url in all where FileManager.default.fileExists(atPath: url.path) {
            let dest = dir.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: url, to: dest)
        }
    }

    /// The logs that exist, for the share button.
    static var shareable: [URL] {
        all
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            + captures
    }

    /// Frame captures written by the compositor (capture-<frame>-*.png).
    static var captures: [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("capture-") && $0.pathExtension == "png" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The last `bytes` of a log, for showing in the app.
    static func tail(_ url: URL, bytes: Int = 16_384) -> String {
        guard let h = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > UInt64(bytes) ? size - UInt64(bytes) : 0)
        return String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
    }

    static func bytes(_ n: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: n), countStyle: .file)
    }
}

/// Spanish when the system language is Spanish, else English.
func AVPL(_ spanish: String, _ english: String) -> String {
    (Locale.preferredLanguages.first ?? "en").lowercased().hasPrefix("es") ? spanish : english
}
