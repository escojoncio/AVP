// AVP: the Steam side of the launcher (sign-in, ownership, download, Steam Cloud), on top of the
// Steam client in app/Steam (adapted from Glovebox's SteamLauncherKit, MIT). Only the refresh
// token is kept (Keychain); the password never is.

import Foundation
import Security
import UIKit

/// The Steam refresh token lives in the Keychain, never in files or UserDefaults. It is revocable
/// from the Steam app or store site ("Deauthorize all devices").
enum AVPKeychain {
    private static let service = "avp.steam-credentials"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func save(_ creds: SteamCredentials) {
        guard let data = try? JSONEncoder().encode(creds) else { return }
        SecItemDelete(query("current") as CFDictionary)
        var q = query("current")
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
        if let g = creds.guardData { setGuardData(g, for: creds.accountName) }
    }

    static func load() -> SteamCredentials? {
        var q = query("current")
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(SteamCredentials.self, from: data)
    }

    static func clear() { SecItemDelete(query("current") as CFDictionary) }

    /// Steam Guard "remember this device" data, so the next password sign-in skips the code.
    static func guardData(for account: String) -> String? {
        var q = query("guard." + account.lowercased())
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    private static func setGuardData(_ g: String, for account: String) {
        let key = "guard." + account.lowercased()
        SecItemDelete(query(key) as CFDictionary)
        var q = query(key)
        q[kSecValueData as String] = Data(g.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }
}

/// The system's background downloads (BackgroundChunkFetcher): one per install folder. The app
/// delegate must forward handleEventsForBackgroundURLSession to `handleEvents` (AVPAppDelegate).
enum AVPBackground {
    static let identifier = (Bundle.main.bundleIdentifier ?? "com.kdt.livecontainer") + ".avp-chunks"
    nonisolated(unsafe) private static var current: BackgroundChunkFetcher?
    private static let lock = NSLock()

    static func fetcher(for root: URL) -> BackgroundChunkFetcher {
        lock.lock(); defer { lock.unlock() }
        if let f = current, f.staged.folder == StagedChunks(installRoot: root).folder { return f }
        let f = BackgroundChunkFetcher(identifier: identifier, installRoot: root)
        f.log = { AVPLog.log("Descarga: \($0)") }
        current = f
        return f
    }
}

/// For the app's UIApplicationDelegate (KleptonApp's @UIApplicationDelegateAdaptor): the system
/// wakes the app with finished background chunk downloads.
final class AVPAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == AVPBackground.identifier, let game = AVPFolder.shared.game else {
            completionHandler()
            return
        }
        AVPLog.log("Descarga: el sistema entrega trozos en segundo plano")
        AVPBackground.fetcher(for: game).handleEvents(completion: completionHandler)
    }
}

extension SteamError {
    /// A sentence for the player.
    var friendly: String {
        switch self {
        case .result(let r, _) where r == .invalidPassword:
            return AVPL("Usuario o contraseña incorrectos.", "Wrong account name or password.")
        case .result(let r, _) where r == .rateLimitExceeded:
            return AVPL("Demasiados intentos. Espera unos minutos.", "Too many attempts. Wait a few minutes.")
        case .result(let r, _) where r == .invalidLoginAuthCode || r == .twoFactorCodeMismatch:
            return AVPL("El código no es correcto.", "The code is not correct.")
        case .result(let r, _) where r == .accessDenied:
            return AVPL("Steam ha denegado el acceso.", "Steam denied access.")
        case .passwordTooLong:
            return AVPL("La contraseña es demasiado larga. Comprueba que la has escrito bien.",
                        "The password is too long. Please check you typed it correctly.")
        case .noServers, .notConnected, .disconnected, .timeout:
            return AVPL("No se pudo conectar con Steam. Comprueba la conexión.", "Could not reach Steam. Check the connection.")
        default:
            return description
        }
    }
}

func avpFriendly(_ error: Error) -> String {
    if let s = error as? SteamError { return s.friendly }
    if let u = error as? URLError {
        return AVPL("Error de red (\(u.code.rawValue)). Comprueba la conexión.", "Network error (\(u.code.rawValue)). Check the connection.")
    }
    return (error as? LocalizedError)?.errorDescription ?? "\(error)"
}
