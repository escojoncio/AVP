// AVP: the launcher's look. Hero backdrop with crossfading screenshots and a slow push-in, pill
// buttons and a few colours, derived from Glovebox's launcher (Theme.swift, LandingView.swift,
// LibraryView.swift).
//
// Portions derived from Glovebox — MIT License, Copyright (c) 2026 the Glovebox contributors.
// Permission is hereby granted, free of charge, to any person obtaining a copy of this software and
// associated documentation files, to deal in the Software without restriction, subject to the
// condition that the copyright notice and this permission notice are included in all copies or
// substantial portions of the Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND.
//
// No game art is bundled: the images are fetched at runtime from Steam's official CDN (the same URLs
// the Steam client and store use for the game) and cached in Library/Caches/AVP/art.

import SwiftUI
import UIKit

enum AVPTheme {
    static let accent = Color(red: 1, green: 0.624, blue: 0.18)        // warm orange
    static let navy = Color(red: 0.09, green: 0.10, blue: 0.13)
    static let warn = Color(red: 1, green: 0.42, blue: 0.30)
    static let ok = Color(red: 0.45, green: 0.82, blue: 0.40)
}

/// Downloads Steam CDN art once and keeps it on disk so the launcher looks the same offline.
enum AVPArtCache {
    static let dir: URL = {
        let u = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AVP/art", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    @MainActor private static var memory: [URL: UIImage] = [:]

    static func file(for url: URL) -> URL {
        // ".../546560/ss_<hash>.1920x1080.jpg" -> "ss_<hash>.1920x1080.jpg"; keep the app id in front.
        let name = url.pathComponents.suffix(2).joined(separator: "_")
        return dir.appendingPathComponent(name)
    }

    /// The immersive space's loading panel (KleptonCompositor.loadingArt): [hero, logo] as files already in the
    /// cache, "" for one not cached (nothing is downloaded for it). Any thread.
    static func loadingPanelFiles() -> [String] {
        let g = GameProfile.halfLifeAlyx
        return [g.heroImageURL, g.logoURL].map { file(for: $0).path }.map { FileManager.default.fileExists(atPath: $0) ? $0 : "" }
    }

    @MainActor static func cached(_ url: URL) -> UIImage? {
        if let i = memory[url] { return i }
        if let d = try? Data(contentsOf: file(for: url)), let i = UIImage(data: d) {
            memory[url] = i
            return i
        }
        return nil
    }

    @MainActor static func image(_ url: URL) async -> UIImage? {
        if let i = cached(url) { return i }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200, let i = UIImage(data: data) else { return nil }
            try? data.write(to: file(for: url), options: .atomic)
            memory[url] = i
            return i
        } catch {
            return nil
        }
    }
}

/// One piece of art from the cache, or `placeholder` until (or unless) it arrives.
struct AVPArtImage<Placeholder: View>: View {
    let url: URL
    let fit: Bool
    let placeholder: () -> Placeholder
    @State private var image: UIImage?

    init(url: URL, fit: Bool = false, @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url
        self.fit = fit
        self.placeholder = placeholder
    }

    var body: some View {
        ZStack {
            if let image {
                if fit {
                    Image(uiImage: image).resizable().scaledToFit().transition(.opacity)
                } else {
                    Image(uiImage: image).resizable().scaledToFill().transition(.opacity)
                }
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            if image == nil { image = AVPArtCache.cached(url) }
            if image == nil {
                let i = await AVPArtCache.image(url)
                withAnimation(.easeOut(duration: 0.6)) { image = i }
            }
        }
    }
}

/// Full-bleed backdrop: the library hero, then in-game screenshots crossfading with a slow push-in
/// (Ken Burns), under a dark gradient for legible text. A dark gradient alone if nothing loads.
struct AVPBackdrop: View {
    private let urls: [URL] = [GameProfile.halfLifeAlyx.heroImageURL] + GameProfile.halfLifeAlyx.screenshotURLs
    @State private var index = 0
    @State private var pushed = false
    private let timer = Timer.publish(every: 9, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            ZStack {
                LinearGradient(colors: [Color(red: 0.25, green: 0.18, blue: 0.10), AVPTheme.navy],
                               startPoint: .topTrailing, endPoint: .bottomLeading)
                ForEach(Array(urls.enumerated()), id: \.offset) { i, url in
                    // Only the previous (fading out), current and next image are in the tree.
                    if i == index || i == (index + 1) % urls.count || i == (index + urls.count - 1) % urls.count {
                        AVPArtImage(url: url) { Color.clear }
                            .frame(width: geo.size.width, height: geo.size.height)
                            .scaleEffect(i == index && pushed ? 1.10 : 1.0)
                            .animation(.linear(duration: 10), value: pushed)
                            .opacity(i == index ? 1 : 0)
                            .animation(.easeInOut(duration: 1.6), value: index)
                            .clipped()
                    }
                }
                // Only a subtle bottom gradient, so the logo reads without covering the art.
                LinearGradient(stops: [.init(color: .clear, location: 0.6),
                                       .init(color: .black.opacity(0.7), location: 1)],
                               startPoint: .top, endPoint: .bottom)
                AVPGameLogo(height: 110)
                    .padding(.leading, 40).padding(.bottom, 36)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onAppear { pushed = true }
        .onReceive(timer) { _ in
            guard urls.count > 1 else { return }
            pushed = false
            index = (index + 1) % urls.count
            // Restart the push-in for the new image on the next run loop turn.
            DispatchQueue.main.async { pushed = true }
        }
    }
}

/// The game's logo from the CDN, or its name in heavy type if the logo isn't available.
struct AVPGameLogo: View {
    var height: CGFloat = 120
    var body: some View {
        AVPArtImage(url: GameProfile.halfLifeAlyx.logoURL, fit: true) {
            Text("Half-Life: Alyx").font(.system(size: height * 0.45, weight: .heavy)).foregroundStyle(.white)
                .lineLimit(1).minimumScaleFactor(0.5)
        }
        .frame(maxWidth: height * 3.6, maxHeight: height, alignment: .leading)
        .shadow(color: .black.opacity(0.6), radius: 18)
        .accessibilityLabel("Half-Life: Alyx")
    }
}

/// A white pill for the one thing to do, translucent glass for the rest.
struct AVPPillButtonStyle: ButtonStyle {
    var prominent = true
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .environment(\.colorScheme, prominent ? .light : .dark)
            .foregroundStyle(prominent ? Color.black : .white)
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(prominent ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.white.opacity(0.16)), in: .capsule)
            .contentShape(.hoverEffect, .capsule)
            .hoverEffect(.highlight)
            .opacity(enabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A slim rounded progress bar in the accent colour.
struct AVPBar: View {
    let fraction: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.14))
                Capsule().fill(LinearGradient(colors: [AVPTheme.accent.opacity(0.8), AVPTheme.accent],
                                              startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(6, geo.size.width * min(max(fraction, 0), 1)))
                    .animation(.easeOut(duration: 0.4), value: fraction)
            }
        }
        .frame(height: 6)
    }
}
