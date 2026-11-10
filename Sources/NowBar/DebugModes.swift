import AppKit
import SwiftUI

/// Offline checks that don't need Spotify, the screen, or any permission.
///
/// - `--render-test <dir>` draws the bar at several sizes and states into PNGs, then exits.
/// - `--dump <dir>` (with the real app) writes `state.txt` and `bar.png` after every refresh.
@MainActor
enum DebugModes {
    static func run(_ arguments: [String]) -> Bool {
        guard let index = arguments.firstIndex(of: "--render-test"), index + 1 < arguments.count else { return false }
        let dir = URL(fileURLWithPath: arguments[index + 1])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let now = Date()
        let track = Track(id: "spotify:track:demo", title: "Sample Track",
                          artist: "Sample Artist", album: "Sample Album",
                          duration: 291, artworkURL: URL(string: "https://example.com/art.jpg"))
        let playing = Playback(state: .playing, track: track, position: 12, sampledAt: now,
                               shuffling: true, repeating: false)
        let art = sampleArtwork()
        let cases: [(String, SpotifyClient, CGSize)] = [
            ("wide", SpotifyClient(preview: playing, artwork: art), CGSize(width: 1400, height: 84)),
            ("medium", SpotifyClient(preview: playing, artwork: art), CGSize(width: 900, height: 72)),
            ("compact", SpotifyClient(preview: playing, artwork: art), CGSize(width: 520, height: 84)),
            ("tall", SpotifyClient(preview: playing, artwork: art), CGSize(width: 1100, height: 120)),
            ("paused-noart", SpotifyClient(preview: Playback(state: .paused, track: track, position: 200,
                                                              sampledAt: now, shuffling: false, repeating: true),
                                           artwork: nil), CGSize(width: 1100, height: 84)),
            ("nothing", SpotifyClient(preview: Playback(), artwork: nil), CGSize(width: 1100, height: 84)),
            ("denied", SpotifyClient(preview: Playback(), artwork: nil, permission: .denied), CGSize(width: 1100, height: 84))
        ]
        for (name, client, size) in cases {
            let url = dir.appendingPathComponent("bar-\(name).png")
            if render(client: client, size: size, now: now, to: url) {
                print("Wrote \(url.path)")
            } else {
                print("FAILED \(name)")
            }
        }
        return true
    }

    @discardableResult
    static func render(client: SpotifyClient, size: CGSize, now: Date?, to url: URL) -> Bool {
        let view = BarView(client: client, settings: Settings.shared, dragger: nil, fixedNow: now)
            .frame(width: size.width, height: size.height)
            .background(
                RoundedRectangle(cornerRadius: BarView.cornerRadius)
                    .fill(Color(white: 0.16).opacity(0.96))
            )
            .padding(20)
            .background(LinearGradient(colors: [Color(red: 0.45, green: 0.3, blue: 0.75), Color(red: 0.95, green: 0.5, blue: 0.3)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }

    static func attachDump(to client: SpotifyClient, arguments: [String]) {
        guard let index = arguments.firstIndex(of: "--dump"), index + 1 < arguments.count else { return }
        let dir = URL(fileURLWithPath: arguments[index + 1])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        client.onRefresh = { [weak client] in
            guard let client else { return }
            let p = client.playback
            let lines = [
                "time: \(Date())",
                "running: \(client.isRunning)",
                "permission: \(client.permission)",
                "state: \(p.state.rawValue)",
                "title: \(p.track?.title ?? "-")",
                "artist: \(p.track?.artist ?? "-")",
                "album: \(p.track?.album ?? "-")",
                "duration: \(p.track?.duration ?? 0)",
                "position: \(p.position)",
                "shuffling: \(p.shuffling)",
                "repeating: \(p.repeating)",
                "artworkURL: \(p.track?.artworkURL?.absoluteString ?? "-")",
                "raw: \(client.lastScriptResult)",
                "artwork: \(client.artwork.map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? "none")"
            ]
            try? lines.joined(separator: "\n").write(to: dir.appendingPathComponent("state.txt"), atomically: true, encoding: .utf8)
            render(client: client, size: CGSize(width: 1100, height: 84), now: nil, to: dir.appendingPathComponent("bar.png"))
        }
    }

    /// A stand-in album cover: coloured dots on cream, so the render shows where art sits.
    private static func sampleArtwork() -> NSImage {
        NSImage(size: NSSize(width: 300, height: 300), flipped: true) { rect in
            NSColor(srgbRed: 0.96, green: 0.95, blue: 0.92, alpha: 1).setFill()
            rect.fill()
            let colors: [NSColor] = [.systemRed, .systemBlue, .systemGreen, .systemYellow, .systemOrange,
                                     .systemPurple, .systemTeal, .systemPink, .black, .systemBrown]
            var index = 0
            for row in 0..<10 {
                for col in 0..<10 {
                    colors[(index * 7 + row) % colors.count].setFill()
                    NSBezierPath(ovalIn: NSRect(x: 18 + CGFloat(col) * 27, y: 18 + CGFloat(row) * 27, width: 14, height: 14)).fill()
                    index += 1
                }
            }
            return true
        }
    }
}
