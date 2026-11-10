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
        // Sample lyrics: a line already running at 12 s (the sample position), and one with word timings.
        let lineLyrics = LyricsStore(preview: .synced(Lyrics(lines: [
            LyricLine(start: 10.5, end: nil, text: "Sample lyrics show up here, one line at a time", words: []),
            LyricLine(start: 15, end: nil, text: "and the next line waits underneath", words: [])
        ])))
        let wordText = ["Words ", "light ", "up ", "as ", "they're ", "sung"]
        let wordLyrics = LyricsStore(preview: .synced(Lyrics(lines: [
            LyricLine(start: 11, end: 14, text: wordText.joined(),
                      words: wordText.enumerated().map { LyricWord(start: 11 + Double($0.offset) * 0.45, text: $0.element) }),
            LyricLine(start: 15, end: nil, text: "when the song has word timings", words: [])
        ])))
        let noLyrics = LyricsStore(preview: .notFound)
        let sunset = sunsetArtwork()
        let ocean = oceanArtwork()
        let cases: [(String, SpotifyClient, LyricsStore, CGSize)] = [
            ("wide-lyrics", SpotifyClient(preview: playing, artwork: art), lineLyrics, CGSize(width: 1400, height: 84)),
            ("wide-words", SpotifyClient(preview: playing, artwork: art), wordLyrics, CGSize(width: 1400, height: 84)),
            ("medium-lyrics", SpotifyClient(preview: playing, artwork: art), lineLyrics, CGSize(width: 900, height: 72)),
            ("compact-lyrics", SpotifyClient(preview: playing, artwork: art), wordLyrics, CGSize(width: 520, height: 84)),
            ("tint-sunset", SpotifyClient(preview: playing, artwork: sunset), wordLyrics, CGSize(width: 1400, height: 84)),
            ("tint-ocean", SpotifyClient(preview: playing, artwork: ocean), lineLyrics, CGSize(width: 1100, height: 84)),
            ("tint-compact", SpotifyClient(preview: playing, artwork: sunset), wordLyrics, CGSize(width: 520, height: 84)),
            ("wide", SpotifyClient(preview: playing, artwork: art), noLyrics, CGSize(width: 1400, height: 84)),
            ("medium", SpotifyClient(preview: playing, artwork: art), noLyrics, CGSize(width: 900, height: 72)),
            ("compact", SpotifyClient(preview: playing, artwork: art), noLyrics, CGSize(width: 520, height: 84)),
            ("tall", SpotifyClient(preview: playing, artwork: art), noLyrics, CGSize(width: 1100, height: 120)),
            ("paused-noart", SpotifyClient(preview: Playback(state: .paused, track: track, position: 200,
                                                              sampledAt: now, shuffling: false, repeating: true),
                                           artwork: nil), noLyrics, CGSize(width: 1100, height: 84)),
            ("nothing", SpotifyClient(preview: Playback(), artwork: nil), noLyrics, CGSize(width: 1100, height: 84)),
            ("denied", SpotifyClient(preview: Playback(), artwork: nil, permission: .denied), noLyrics, CGSize(width: 1100, height: 84))
        ]
        for (name, client, lyrics, size) in cases {
            let url = dir.appendingPathComponent("bar-\(name).png")
            if render(client: client, lyrics: lyrics, size: size, now: now, to: url) {
                print("Wrote \(url.path)")
            } else {
                print("FAILED \(name)")
            }
        }
        return true
    }

    @discardableResult
    static func render(client: SpotifyClient, lyrics: LyricsStore, size: CGSize, now: Date?, to url: URL) -> Bool {
        let view = BarView(client: client, settings: Settings.shared, lyrics: lyrics, dragger: nil, fixedNow: now)
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

    static func attachDump(to client: SpotifyClient, lyrics: LyricsStore, arguments: [String]) {
        guard let index = arguments.firstIndex(of: "--dump"), index + 1 < arguments.count else { return }
        let dir = URL(fileURLWithPath: arguments[index + 1])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        client.onRefresh = { [weak client, weak lyrics] in
            guard let client, let lyrics else { return }
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
                "lyrics: \(Self.describe(lyrics.status, at: p.position(at: Date())))",
                "artwork: \(client.artwork.map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? "none")"
            ]
            try? lines.joined(separator: "\n").write(to: dir.appendingPathComponent("state.txt"), atomically: true, encoding: .utf8)
            render(client: client, lyrics: lyrics, size: CGSize(width: 1100, height: 84), now: Date(), to: dir.appendingPathComponent("bar.png"))
        }
    }

    private static func describe(_ status: LyricsStatus, at time: Double) -> String {
        guard case .synced(let lyrics) = status else { return "\(status)" }
        let index = lyrics.lineIndex(at: time + LyricsView.lead)
        let line = index.map { lyrics.lines[$0].text } ?? "(before first line)"
        return "synced, \(lyrics.lines.count) lines, word timing \(lyrics.hasWordTiming), now: \(line)"
    }

    /// A stand-in cover with strong colours: a purple-to-orange sky with a pale sun.
    private static func sunsetArtwork() -> NSImage {
        NSImage(size: NSSize(width: 300, height: 300), flipped: false) { rect in
            NSGradient(colors: [NSColor(srgbRed: 0.98, green: 0.55, blue: 0.2, alpha: 1),
                                NSColor(srgbRed: 0.85, green: 0.25, blue: 0.45, alpha: 1),
                                NSColor(srgbRed: 0.3, green: 0.12, blue: 0.5, alpha: 1)])?.draw(in: rect, angle: 90)
            NSColor(srgbRed: 1, green: 0.88, blue: 0.6, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 95, y: 70, width: 110, height: 110)).fill()
            NSColor(srgbRed: 0.12, green: 0.05, blue: 0.2, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 300, height: 80).fill()
            return true
        }
    }

    /// A stand-in cover in blues and teals.
    private static func oceanArtwork() -> NSImage {
        NSImage(size: NSSize(width: 300, height: 300), flipped: false) { rect in
            NSGradient(colors: [NSColor(srgbRed: 0.05, green: 0.15, blue: 0.35, alpha: 1),
                                NSColor(srgbRed: 0.1, green: 0.55, blue: 0.65, alpha: 1)])?.draw(in: rect, angle: 90)
            NSColor(white: 1, alpha: 0.8).setStroke()
            for row in 0..<6 {
                let path = NSBezierPath()
                path.lineWidth = 4
                path.move(to: NSPoint(x: 0, y: 40 + row * 40))
                path.curve(to: NSPoint(x: 300, y: 40 + row * 40), controlPoint1: NSPoint(x: 100, y: 70 + row * 40),
                           controlPoint2: NSPoint(x: 200, y: 10 + row * 40))
                path.stroke()
            }
            return true
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
