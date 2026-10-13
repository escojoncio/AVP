// Adapted from Glovebox's SteamLauncherKit (MIT, Copyright (c) 2026 the Glovebox contributors;
// see app/Steam/GLOVEBOX-LICENSE.txt).
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A binary message pipe to a Steam connection manager (CM). On Apple platforms this is the
/// same WebSocket (`wss://<cm>/cmsocket/`) the Steam client and SteamKit2 use.
public protocol CMTransport: AnyObject {
    func connect(url: URL) async throws
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func close()
}

public enum TransportError: Error, CustomStringConvertible {
    case closed
    case unexpectedMessage
    case bridge(String)
    public var description: String {
        switch self {
        case .closed: return "the connection to Steam closed"
        case .unexpectedMessage: return "Steam sent a text frame on a binary socket"
        case .bridge(let s): return "WebSocket bridge: \(s)"
        }
    }
}

public final class WebSocketTransport: CMTransport {
    private var task: URLSessionWebSocketTask?
    private let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func connect(url: URL) async throws {
        let t = session.webSocketTask(with: url)
        t.maximumMessageSize = 64 << 20
        task = t
        t.resume()
    }

    public func send(_ data: Data) async throws {
        guard let task else { throw TransportError.closed }
        try await task.send(.data(data))
    }

    public func receive() async throws -> Data {
        guard let task else { throw TransportError.closed }
        switch try await task.receive() {
        case .data(let d): return d
        default: throw TransportError.unexpectedMessage
        }
    }

    public func close() {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }
}

public enum Transports {
    /// The default transport for this platform.
    public static func make() -> CMTransport {
        return WebSocketTransport()
    }
}
