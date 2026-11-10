import Combine
import Foundation

// Time-synced lyrics from LRCLIB (https://lrclib.net), a free, open lyrics database. Spotify doesn't
// expose its own lyrics to other apps, so NowBar looks the current track up by title, artist, album
// and duration. Some tracks have word-level timing too, which NowBar uses to fill the line as it's sung.

struct LyricWord: Equatable {
    /// Seconds into the track.
    let start: Double
    /// Includes its trailing space, so joining the words gives the line.
    let text: String
}

struct LyricLine: Equatable {
    let start: Double
    let end: Double?
    let text: String
    /// Empty when only the line's start time is known.
    let words: [LyricWord]
}

struct Lyrics: Equatable {
    let lines: [LyricLine]

    var hasWordTiming: Bool { lines.contains { !$0.words.isEmpty } }

    /// The last line that has started by `time`, or nil before the first line.
    func lineIndex(at time: Double) -> Int? {
        var low = 0, high = lines.count - 1, found: Int?
        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].start <= time {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return found
    }
}

enum LyricsStatus: Equatable {
    /// Lyrics are turned off.
    case off
    /// Nothing to look up (no track, or a podcast or ad).
    case idle
    case loading
    case synced(Lyrics)
    /// LRCLIB has the words but no timings, so they can't follow the song.
    case unsynced
    case instrumental
    case notFound
    /// LRCLIB couldn't be reached. Tried again shortly.
    case failed
}

// MARK: - Store

/// Looks up lyrics whenever the track changes, and keeps recent results.
@MainActor
final class LyricsStore: ObservableObject {
    @Published private(set) var status: LyricsStatus = .idle

    private var trackKey: String?
    private var cache: [String: LyricsStatus] = [:]
    private var cacheOrder: [String] = []
    private var task: Task<Void, Never>?
    private var subscriptions = Set<AnyCancellable>()

    init(client: SpotifyClient, settings: Settings) {
        client.$playback
            .map(\.track)
            .removeDuplicates()
            .combineLatest(settings.$showLyrics)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] track, enabled in self?.update(track: track, enabled: enabled) }
            .store(in: &subscriptions)
    }

    /// Fixed lyrics for offline renders.
    init(preview status: LyricsStatus) {
        self.status = status
    }

    private func update(track: Track?, enabled: Bool, retrying: Bool = false) {
        guard enabled else {
            task?.cancel()
            trackKey = nil
            status = .off
            return
        }
        guard let track, !track.title.isEmpty, !track.id.hasPrefix("spotify:episode:"),
              !track.id.hasPrefix("spotify:ad:") else {
            task?.cancel()
            trackKey = nil
            status = .idle
            return
        }
        let key = track.id.isEmpty ? "\(track.artist)|\(track.title)" : track.id
        guard key != trackKey || retrying else { return }
        trackKey = key
        task?.cancel()
        if let cached = cache[key] {
            status = cached
            return
        }
        status = .loading
        task = Task { [weak self] in
            let result = await LRCLib.lookUp(track)
            guard !Task.isCancelled, let self, self.trackKey == key else { return }
            self.status = result
            if result == .failed {
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled, self.trackKey == key else { return }
                self.update(track: track, enabled: true, retrying: true)
            } else {
                self.remember(result, for: key)
            }
        }
    }

    private func remember(_ status: LyricsStatus, for key: String) {
        cache[key] = status
        cacheOrder.append(key)
        if cacheOrder.count > 60 { cache.removeValue(forKey: cacheOrder.removeFirst()) }
    }
}

// MARK: - LRCLIB

enum LRCLib {
    private static let base = URL(string: "https://lrclib.net/api/")!

    /// LRCLIB asks clients to identify themselves.
    private static let userAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return "NowBar/\(version) (https://github.com/nathanm95/nowbar)"
    }()

    private struct Record: Decodable {
        let duration: Double?
        let instrumental: Bool?
        let plainLyrics: String?
        let syncedLyrics: String?
        let lyricsfile: String?
    }

    /// Exact match first. If that has no timings, search for a synced copy with a matching length.
    static func lookUp(_ track: Track) async -> LyricsStatus {
        do {
            let exact = try await get(track)
            if let exact, let status = synced(from: exact) { return status }
            if exact?.instrumental == true { return .instrumental }
            if let found = try await search(track), let status = synced(from: found) { return status }
            if let plain = exact?.plainLyrics, !plain.isEmpty { return .unsynced }
            return .notFound
        } catch {
            return .failed
        }
    }

    private static func get(_ track: Track) async throws -> Record? {
        var items = [URLQueryItem(name: "track_name", value: track.title),
                     URLQueryItem(name: "artist_name", value: track.artist)]
        if !track.album.isEmpty { items.append(URLQueryItem(name: "album_name", value: track.album)) }
        if track.duration > 0 { items.append(URLQueryItem(name: "duration", value: String(Int(track.duration.rounded())))) }
        return try await request("get", items, as: Record.self)
    }

    private static func search(_ track: Track) async throws -> Record? {
        let items = [URLQueryItem(name: "track_name", value: simplified(track.title)),
                     URLQueryItem(name: "artist_name", value: track.artist)]
        let records = try await request("search", items, as: [Record].self) ?? []
        let synced = records.filter { !($0.syncedLyrics ?? "").isEmpty }
        guard track.duration > 0 else { return synced.first }
        return synced
            .filter { abs(($0.duration ?? 0) - track.duration) <= 5 }
            .min { abs(($0.duration ?? 0) - track.duration) < abs(($1.duration ?? 0) - track.duration) }
    }

    private static func request<T: Decodable>(_ path: String, _ items: [URLQueryItem], as: T.Type) async throws -> T? {
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = items
        var request = URLRequest(url: components.url!, timeoutInterval: 12)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { return nil }
        guard (200..<300).contains(code) else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func synced(from record: Record) -> LyricsStatus? {
        if record.instrumental == true { return .instrumental }
        if let file = record.lyricsfile, let lines = LyricsParser.lyricsfile(file), !lines.isEmpty {
            return .synced(Lyrics(lines: lines))
        }
        if let lrc = record.syncedLyrics {
            let lines = LyricsParser.lrc(lrc)
            if !lines.isEmpty { return .synced(Lyrics(lines: lines)) }
        }
        return nil
    }

    /// "Song - 2011 Remaster (feat. Someone)" becomes "Song", for the fallback search.
    static func simplified(_ title: String) -> String {
        var result = title
        for pattern in [#"\s+-\s+.*$"#, #"\s*[\(\[](feat|ft|with)\.?\s[^\)\]]*[\)\]]"#] {
            result = result.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        return result.trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Parsing

enum LyricsParser {
    private static let timestamp = try! NSRegularExpression(pattern: #"\[(\d+):(\d+(?:[.:]\d+)?)\]"#)

    /// Parses LRC: `[mm:ss.xx] words`. A line may carry several timestamps. Empty lines mark breaks.
    static func lrc(_ text: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        for raw in text.components(separatedBy: .newlines) {
            let ns = raw as NSString
            var times: [Double] = []
            var rest = 0
            for match in timestamp.matches(in: raw, range: NSRange(location: 0, length: ns.length)) {
                guard match.range.location == rest else { break } // Timestamps only count at the start.
                let minutes = Double(ns.substring(with: match.range(at: 1))) ?? 0
                let seconds = Double(ns.substring(with: match.range(at: 2)).replacingOccurrences(of: ":", with: ".")) ?? 0
                times.append(minutes * 60 + seconds)
                rest = match.range.location + match.range.length
            }
            guard !times.isEmpty else { continue }
            let words = ns.substring(from: rest).trimmingCharacters(in: .whitespaces)
            for time in times {
                lines.append(LyricLine(start: time, end: nil, text: words, words: []))
            }
        }
        return lines.sorted { $0.start < $1.start }
    }

    /// Parses LRCLIB's `lyricsfile`, a small YAML document with line and word timings:
    ///
    ///     lines:
    ///     - text: Some words here
    ///       start_ms: 22870
    ///       end_ms: 25695
    ///       words:
    ///       - text: 'Some '
    ///         start_ms: 22870
    ///
    /// Only that shape is understood. A line whose words don't add up to its text keeps its line
    /// timing but loses its word timing. Returns nil if the document doesn't look right at all.
    static func lyricsfile(_ text: String) -> [LyricLine]? {
        struct Building {
            var text = ""
            var start: Int?
            var end: Int?
            var words: [(text: String, start: Int?)] = []
        }
        var lines: [LyricLine] = []
        var current: Building?
        var inLines = false

        func finish() {
            guard let line = current, let start = line.start else { return }
            var words = line.words.compactMap { word in word.start.map { LyricWord(start: Double($0) / 1000, text: word.text) } }
            let joined = words.map(\.text).joined().trimmingCharacters(in: .whitespaces)
            if words.count != line.words.count || joined != line.text.trimmingCharacters(in: .whitespaces) { words = [] }
            lines.append(LyricLine(start: Double(start) / 1000, end: line.end.map { Double($0) / 1000 },
                                   text: line.text, words: words))
        }

        for raw in text.components(separatedBy: .newlines) {
            if raw == "lines:" { inLines = true; continue }
            guard inLines else { continue }
            if let value = field(raw, prefix: "- text:") {
                finish()
                current = Building(text: scalar(value))
            } else if let value = field(raw, prefix: "  start_ms:") {
                current?.start = Int(value)
            } else if let value = field(raw, prefix: "  end_ms:") {
                current?.end = Int(value)
            } else if let value = field(raw, prefix: "  - text:") {
                current?.words.append((scalar(value), nil))
            } else if let value = field(raw, prefix: "    start_ms:") {
                if let last = current?.words.indices.last { current?.words[last].start = Int(value) }
            } else if !raw.hasPrefix(" ") && !raw.isEmpty && !raw.hasPrefix("-") {
                break // A new top-level key: the lines are over.
            }
        }
        finish()
        return lines.isEmpty ? nil : lines.sorted { $0.start < $1.start }
    }

    private static func field(_ line: String, prefix: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    /// A YAML scalar: 'single quoted' ('' is a quote), "double quoted" (JSON-style escapes), or plain.
    private static func scalar(_ value: String) -> String {
        if value.count >= 2, value.hasPrefix("'"), value.hasSuffix("'") {
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\""),
           let data = value.data(using: .utf8), let decoded = try? JSONDecoder().decode(String.self, from: data) {
            return decoded
        }
        return value
    }
}
