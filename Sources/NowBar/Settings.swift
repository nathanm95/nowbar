import AppKit
import Combine

/// User choices, saved in UserDefaults.
@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    /// Show the bar whenever Spotify is open. Off hides it until turned back on.
    @Published var showBar: Bool { didSet { defaults.set(showBar, forKey: "showBar") } }
    /// Float above other windows. Off puts the bar on the desktop, behind windows.
    @Published var onTop: Bool { didSet { defaults.set(onTop, forKey: "onTop") } }
    /// Show on every desktop (Space). Off keeps it on one desktop.
    @Published var allDesktops: Bool { didSet { defaults.set(allDesktops, forKey: "allDesktops") } }
    /// Show time-synced lyrics from LRCLIB above the scrubber.
    @Published var showLyrics: Bool { didSet { defaults.set(showLyrics, forKey: "showLyrics") } }
    /// Tint the see-through bar with colours from the album art.
    @Published var tintFromArtwork: Bool { didSet { defaults.set(tintFromArtwork, forKey: "tintFromArtwork") } }
    /// Stop the bar being moved or resized by dragging.
    @Published var locked: Bool { didSet { defaults.set(locked, forKey: "locked") } }

    var frame: NSRect? {
        get { defaults.string(forKey: "frame").map(NSRectFromString).flatMap { $0.isEmpty ? nil : $0 } }
        set { defaults.set(newValue.map(NSStringFromRect), forKey: "frame") }
    }

    private init() {
        defaults.register(defaults: ["showBar": true, "showLyrics": true, "tintFromArtwork": true, "onTop": true, "allDesktops": false, "locked": false])
        showBar = defaults.bool(forKey: "showBar")
        onTop = defaults.bool(forKey: "onTop")
        allDesktops = defaults.bool(forKey: "allDesktops")
        locked = defaults.bool(forKey: "locked")
        showLyrics = defaults.bool(forKey: "showLyrics")
        tintFromArtwork = defaults.bool(forKey: "tintFromArtwork")
    }
}
