import AppKit
import Combine

enum PlayerState: String {
    case playing, paused, stopped
}

struct Track: Equatable {
    var id: String
    var title: String
    var artist: String
    var album: String
    /// Seconds.
    var duration: Double
    var artworkURL: URL?
}

struct Playback: Equatable {
    var state: PlayerState = .stopped
    var track: Track?
    /// Seconds into the track when `sampledAt` was taken.
    var position: Double = 0
    var sampledAt = Date()
    var shuffling = false
    var repeating = false

    /// Where playback is now, counting forward from the last sample while playing.
    func position(at date: Date) -> Double {
        var seconds = position
        if state == .playing { seconds += date.timeIntervalSince(sampledAt) }
        let upper = (track?.duration ?? 0) > 0 ? track!.duration : seconds
        return min(max(0, seconds), upper)
    }
}

enum AutomationPermission {
    case unknown, granted, denied
}

/// Reads Spotify's state through its AppleScript dictionary and sends it commands.
///
/// Spotify posts `com.spotify.client.PlaybackStateChanged` on track and play/pause changes, which
/// triggers an immediate refresh. A slow poll catches the rest (seeks, shuffle, repeat). Every
/// script checks Spotify is running first, so NowBar never relaunches it after you quit it.
@MainActor
final class SpotifyClient: ObservableObject {
    nonisolated static let bundleID = "com.spotify.client"

    @Published private(set) var isRunning = false
    @Published private(set) var playback = Playback()
    @Published private(set) var artwork: NSImage? {
        didSet {
            guard artwork !== oldValue else { return }
            palette = artwork.flatMap(PaletteExtractor.palette)
        }
    }
    /// Colours from the current album art, for the bar's tint.
    @Published private(set) var palette: ArtworkPalette?
    @Published private(set) var permission: AutomationPermission = .unknown

    /// True while the bar is on screen. Polling only runs while active.
    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            updatePolling()
            if isActive { refresh() }
        }
    }

    /// Called after every refresh. Used by `--dump`.
    var onRefresh: (() -> Void)?
    /// The last script result or error, for `--dump`.
    private(set) var lastScriptResult = ""

    private let isPreview: Bool
    private var pollTimer: Timer?
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    private var checkingPermission = false
    private var artworkCache: [URL: NSImage] = [:]
    private var artworkCacheOrder: [URL] = []
    private var artworkTask: URLSessionDataTask?
    private var requestedArtworkURL: URL?
    private var pendingRefresh: DispatchWorkItem?

    init() {
        isPreview = false
        isRunning = Self.spotifyIsRunning()
        observe()
    }

    /// A client with fixed state that never talks to Spotify. Used by `--render-test`.
    init(preview playback: Playback, artwork: NSImage?, permission: AutomationPermission = .granted) {
        isPreview = true
        isRunning = true
        self.playback = playback
        self.artwork = artwork
        self.palette = artwork.flatMap(PaletteExtractor.palette)
        self.permission = permission
    }

    // MARK: - Commands

    func playPause() {
        let now = Date()
        var updated = playback
        updated.position = playback.position(at: now)
        updated.sampledAt = now
        updated.state = playback.state == .playing ? .paused : .playing
        playback = updated
        send("playpause")
    }

    func nextTrack() { send("next track") }

    func previousTrack() { send("previous track") }

    func seek(to seconds: Double) {
        var updated = playback
        updated.position = seconds
        updated.sampledAt = Date()
        playback = updated
        send("set player position to \(String(format: "%.2f", seconds))", refreshAfter: 0.5)
    }

    func toggleShuffle() {
        let value = !playback.shuffling
        playback.shuffling = value
        send("set shuffling to \(value)", refreshAfter: 0.5)
    }

    func toggleRepeat() {
        let value = !playback.repeating
        playback.repeating = value
        send("set repeating to \(value)", refreshAfter: 0.5)
    }

    func openSpotify() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    static func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Refresh

    func refresh() {
        guard !isPreview else { return }
        isRunning = Self.spotifyIsRunning()
        guard isRunning else { return }
        guard permission == .granted else {
            checkPermission()
            return
        }
        switch AppleScript.run(AppleScript.fetchSource) {
        case .success(let result):
            lastScriptResult = String(describing: result)
            apply(result)
        case .failure(let error):
            lastScriptResult = "error \(error.code): \(error.message)"
            if error.code == AppleScript.notPermitted {
                permission = .denied
            }
        }
        onRefresh?()
    }

    private func scheduleRefresh(after delay: TimeInterval) {
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func send(_ command: String, refreshAfter delay: TimeInterval = 0.3) {
        guard !isPreview, isRunning, permission == .granted else {
            if permission == .denied { Self.openAutomationSettings() }
            return
        }
        let source = AppleScript.guardLine + "tell application id \"\(Self.bundleID)\" to \(command)"
        if case .failure(let error) = AppleScript.run(source), error.code == AppleScript.notPermitted {
            permission = .denied
        }
        scheduleRefresh(after: delay)
    }

    private func apply(_ result: NSAppleEventDescriptor) {
        guard result.numberOfItems >= 1 else {
            // The guard line returned "notrunning": Spotify quit between our check and the script.
            isRunning = Self.spotifyIsRunning()
            return
        }
        let state = PlayerState(rawValue: result.atIndex(1)?.stringValue ?? "") ?? .stopped
        guard state != .stopped, result.numberOfItems >= 10 else {
            playback = Playback(state: .stopped, track: nil, position: 0, sampledAt: Date(),
                                shuffling: playback.shuffling, repeating: playback.repeating)
            loadArtwork(nil)
            return
        }
        func text(_ index: Int) -> String? {
            guard let item = result.atIndex(index), !AppleScript.isMissingValue(item) else { return nil }
            return item.stringValue
        }
        func number(_ index: Int) -> Double {
            guard let item = result.atIndex(index), !AppleScript.isMissingValue(item) else { return 0 }
            return item.doubleValue
        }
        func flag(_ index: Int) -> Bool {
            guard let item = result.atIndex(index), !AppleScript.isMissingValue(item) else { return false }
            return item.booleanValue
        }

        var artworkURL: URL?
        if var link = text(7), !link.isEmpty {
            if link.hasPrefix("http://") { link = "https://" + link.dropFirst("http://".count) }
            artworkURL = URL(string: link)
        }
        let track = Track(id: text(10) ?? "",
                          title: text(2) ?? "",
                          artist: text(3) ?? "",
                          album: text(4) ?? "",
                          // Spotify's dictionary says seconds, but it reports milliseconds.
                          duration: number(5) / 1000,
                          artworkURL: artworkURL)
        playback = Playback(state: state, track: track, position: number(6), sampledAt: Date(),
                            shuffling: flag(8), repeating: flag(9))
        loadArtwork(artworkURL)
    }

    /// Fills in what Spotify's own notification carries, for when NowBar isn't allowed to script it.
    private func apply(notification info: [AnyHashable: Any]) {
        let state = PlayerState(rawValue: (info["Player State"] as? String)?.lowercased() ?? "") ?? .stopped
        guard state != .stopped, let title = info["Name"] as? String else {
            playback = Playback()
            return
        }
        let track = Track(id: info["Track ID"] as? String ?? "",
                          title: title,
                          artist: info["Artist"] as? String ?? "",
                          album: info["Album"] as? String ?? "",
                          duration: ((info["Duration"] as? NSNumber)?.doubleValue ?? 0) / 1000,
                          artworkURL: nil)
        playback = Playback(state: state, track: track,
                            position: (info["Playback Position"] as? NSNumber)?.doubleValue ?? 0,
                            sampledAt: Date(), shuffling: false, repeating: false)
    }

    // MARK: - Permission

    /// Asks macOS whether NowBar may send Apple Events to Spotify, showing the consent prompt the
    /// first time. Runs off the main thread because the call waits for the user to answer.
    private func checkPermission() {
        guard !checkingPermission, isRunning else { return }
        checkingPermission = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let target = NSAppleEventDescriptor(bundleIdentifier: SpotifyClient.bundleID)
            let status = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, true)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.checkingPermission = false
                    switch Int(status) {
                    case Int(noErr):
                        self.permission = .granted
                        self.refresh()
                    case AppleScript.notPermitted:
                        self.permission = .denied
                    default:
                        break // Spotify not running yet, or still launching. Try again on the next tick.
                    }
                }
            }
        }
    }

    // MARK: - Artwork

    private func loadArtwork(_ url: URL?) {
        guard url != requestedArtworkURL else { return }
        requestedArtworkURL = url
        artworkTask?.cancel()
        guard let url else {
            artwork = nil
            return
        }
        if let cached = artworkCache[url] {
            artwork = cached
            return
        }
        artworkTask = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            let image = data.flatMap { NSImage(data: $0) }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.requestedArtworkURL == url else { return }
                    guard let image else {
                        // Leave the URL unrequested so the next refresh tries again.
                        self.requestedArtworkURL = nil
                        self.artwork = nil
                        return
                    }
                    self.cache(image, for: url)
                    self.artwork = image
                }
            }
        }
        artworkTask?.resume()
    }

    private func cache(_ image: NSImage, for url: URL) {
        artworkCache[url] = image
        artworkCacheOrder.append(url)
        if artworkCacheOrder.count > 30 {
            artworkCache.removeValue(forKey: artworkCacheOrder.removeFirst())
        }
    }

    // MARK: - Observing Spotify

    static func spotifyIsRunning() -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains { !$0.isTerminated }
    }

    private func observe() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            let token = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == SpotifyClient.bundleID else { return }
                let launched = name == NSWorkspace.didLaunchApplicationNotification
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isRunning = launched
                    if launched {
                        // Spotify takes a moment before it answers scripts.
                        self.scheduleRefresh(after: 1.5)
                    } else {
                        self.playback = Playback()
                        self.loadArtwork(nil)
                    }
                    self.updatePolling()
                }
            }
            tokens.append((workspace, token))
        }

        let distributed = DistributedNotificationCenter.default()
        let token = distributed.addObserver(forName: NSNotification.Name("com.spotify.client.PlaybackStateChanged"),
                                            object: nil, queue: .main) { [weak self] note in
            let info = note.userInfo ?? [:]
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isRunning = Self.spotifyIsRunning()
                if self.permission == .granted {
                    self.refresh()
                } else {
                    self.apply(notification: info)
                    self.checkPermission()
                }
            }
        }
        tokens.append((distributed, token))
    }

    private func updatePolling() {
        let shouldPoll = isActive && isRunning && !isPreview
        if shouldPoll, pollTimer == nil {
            let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            timer.tolerance = 0.3
            RunLoop.main.add(timer, forMode: .common)
            pollTimer = timer
        } else if !shouldPoll {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }
}

// MARK: - AppleScript

@MainActor
enum AppleScript {
    static let notPermitted = -1743

    /// Stops a script before it can launch Spotify by talking to it.
    static let guardLine = "if application id \"\(SpotifyClient.bundleID)\" is not running then return \"notrunning\"\n"

    static let fetchSource = guardLine + """
    with timeout of 3 seconds
        tell application id "\(SpotifyClient.bundleID)"
            set stateText to player state as string
            if stateText is "stopped" then return {stateText}
            set t to current track
            return {stateText, name of t, artist of t, album of t, duration of t, player position, artwork url of t, shuffling, repeating, id of t}
        end tell
    end timeout
    """

    struct Failure: Error {
        let code: Int
        let message: String
    }

    private static var compiled: [String: NSAppleScript] = [:]

    static func run(_ source: String) -> Result<NSAppleEventDescriptor, Failure> {
        let script: NSAppleScript
        if let cached = compiled[source] {
            script = cached
        } else if let made = NSAppleScript(source: source) {
            script = made
            if compiled.count > 20 { compiled.removeAll() }
            compiled[source] = made
        } else {
            return .failure(Failure(code: -1, message: "Could not create script"))
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let code = (error[NSAppleScript.errorNumber] as? Int) ?? -1
            let message = (error[NSAppleScript.errorMessage] as? String) ?? ""
            return .failure(Failure(code: code, message: message))
        }
        return .success(result)
    }

    static func isMissingValue(_ descriptor: NSAppleEventDescriptor) -> Bool {
        descriptor.descriptorType == typeType && descriptor.typeCodeValue == 0x6D73_6E67 // 'msng'
    }
}
