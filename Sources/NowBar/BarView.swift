import SwiftUI

/// The bar's content: artwork, title, artist and album, scrubber, and transport controls.
///
/// Wide bars lay out in one row. Narrow bars (under `compactWidth`) put the scrubber under the
/// title, like the macOS Now Playing widget.
struct BarView: View {
    @ObservedObject var client: SpotifyClient
    @ObservedObject var settings: Settings
    /// Moves and resizes the window. Nil when rendering offline.
    var dragger: WindowDragger?
    /// A fixed clock for offline renders. Nil means live.
    var fixedNow: Date?

    static let compactWidth: CGFloat = 640
    static let cornerRadius: CGFloat = 14

    /// Seconds under the pointer while the scrubber is being dragged.
    @ViewState private var scrubSeconds: Double?

    var body: some View {
        GeometryReader { geo in
            let metrics = Metrics(size: geo.size)
            Group {
                if geo.size.width >= Self.compactWidth {
                    wideLayout(metrics)
                } else {
                    compactLayout(metrics)
                }
            }
            .padding(metrics.padding)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
        }
        .contentShape(Rectangle())
        .gesture(moveGesture, including: settings.locked ? .subviews : .all)
        .overlay { resizeHandles }
        .overlay {
            // Circular corners, to match the window's mask.
            RoundedRectangle(cornerRadius: Self.cornerRadius)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        .environment(\.colorScheme, .dark)
    }

    // MARK: - Layouts

    private func wideLayout(_ m: Metrics) -> some View {
        HStack(spacing: m.padding * 1.4) {
            artwork(m)
            titleBlock(m, lines: m.size.height >= 70 ? 3 : 2)
                .frame(width: min(380, max(150, m.size.width * 0.24)), alignment: .leading)
            timeline { now in scrubberRow(m, now: now) }
                .frame(maxWidth: .infinity)
            controls(m)
        }
    }

    private func compactLayout(_ m: Metrics) -> some View {
        HStack(spacing: m.padding) {
            artwork(m)
            VStack(alignment: .leading, spacing: m.size.height * 0.07) {
                HStack(alignment: .center, spacing: 8) {
                    titleBlock(m, lines: 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    controls(m)
                }
                timeline { now in scrubberRow(m, now: now) }
            }
        }
    }

    // MARK: - Pieces

    private func artwork(_ m: Metrics) -> some View {
        let side = m.size.height - m.padding * 2
        return ZStack {
            RoundedRectangle(cornerRadius: side * 0.09, style: .continuous)
                .fill(.white.opacity(0.08))
            if let image = client.artwork {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
                    .id(client.playback.track?.artworkURL)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: side * 0.4, weight: .medium))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.09, style: .continuous))
        .animation(.easeInOut(duration: 0.3), value: client.playback.track?.artworkURL)
        .onTapGesture { client.openSpotify() }
        .help("Open Spotify")
    }

    @ViewBuilder
    private func titleBlock(_ m: Metrics, lines: Int) -> some View {
        let track = client.playback.track
        VStack(alignment: .leading, spacing: 1) {
            if let track {
                Text(track.title.isEmpty ? "Unknown track" : track.title)
                    .font(.system(size: m.titleSize, weight: .semibold))
                    .foregroundStyle(.white)
                if lines >= 3 {
                    Text(track.artist)
                        .font(.system(size: m.detailSize))
                        .foregroundStyle(.white.opacity(0.7))
                    Text(track.album)
                        .font(.system(size: m.detailSize))
                        .foregroundStyle(.white.opacity(0.45))
                } else {
                    Text([track.artist, track.album].filter { !$0.isEmpty }.joined(separator: " — "))
                        .font(.system(size: m.detailSize))
                        .foregroundStyle(.white.opacity(0.7))
                }
            } else if client.permission == .denied {
                Text("Let NowBar control Spotify")
                    .font(.system(size: m.titleSize, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Open Privacy & Security › Automation")
                    .font(.system(size: m.detailSize))
                    .underline()
                    .foregroundStyle(Color.accentColor)
                    .onTapGesture { SpotifyClient.openAutomationSettings() }
            } else {
                Text("Nothing playing")
                    .font(.system(size: m.titleSize, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                Text("Spotify")
                    .font(.system(size: m.detailSize))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .lineLimit(1)
        .truncationMode(.tail)
    }

    private func scrubberRow(_ m: Metrics, now: Date) -> some View {
        let duration = client.playback.track?.duration ?? 0
        let position = scrubSeconds ?? client.playback.position(at: now)
        return HStack(spacing: 10) {
            Text(Self.format(position))
                .frame(minWidth: m.timeWidth, alignment: .trailing)
            Scrubber(progress: duration > 0 ? position / duration : 0,
                     enabled: duration > 0,
                     onScrub: { fraction in scrubSeconds = fraction * duration },
                     onCommit: { fraction in
                         client.seek(to: fraction * duration)
                         scrubSeconds = nil
                     })
            Text("-" + Self.format(max(0, duration - position)))
                .frame(minWidth: m.timeWidth, alignment: .leading)
        }
        .font(.system(size: m.timeSize).monospacedDigit())
        .foregroundStyle(.white.opacity(0.6))
    }

    private func controls(_ m: Metrics) -> some View {
        let playback = client.playback
        return HStack(spacing: m.controlSpacing) {
            ControlButton(symbol: "shuffle", size: m.iconSize * 0.85, isOn: playback.shuffling,
                          help: playback.shuffling ? "Shuffle is on" : "Shuffle is off") { client.toggleShuffle() }
            ControlButton(symbol: "backward.fill", size: m.iconSize, help: "Previous") { client.previousTrack() }
            ControlButton(symbol: playback.state == .playing ? "pause.fill" : "play.fill", size: m.iconSize * 1.45,
                          help: playback.state == .playing ? "Pause" : "Play") { client.playPause() }
            ControlButton(symbol: "forward.fill", size: m.iconSize, help: "Next") { client.nextTrack() }
            ControlButton(symbol: "repeat", size: m.iconSize * 0.85, isOn: playback.repeating,
                          help: playback.repeating ? "Repeat is on" : "Repeat is off") { client.toggleRepeat() }
        }
    }

    /// Redraws twice a second while playing so the clock and scrubber move.
    @ViewBuilder
    private func timeline<Content: View>(@ViewBuilder _ content: @escaping (Date) -> Content) -> some View {
        if let fixedNow {
            content(fixedNow)
        } else {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                content(context.date)
            }
        }
    }

    // MARK: - Moving and resizing

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { _ in dragger?.drag(.move) }
            .onEnded { _ in dragger?.end() }
    }

    private var resizeHandles: some View {
        HStack(spacing: 0) {
            ResizeHandle(edge: .left, dragger: dragger)
                .frame(width: 6)
            Spacer(minLength: 0)
            ResizeHandle(edge: .right, dragger: dragger)
                .frame(width: 6)
        }
        .overlay(alignment: .bottom) {
            ResizeHandle(edge: .bottom, dragger: dragger)
                .frame(height: 5)
                .padding(.horizontal, 6)
        }
        .allowsHitTesting(!settings.locked && dragger != nil)
    }

    // MARK: - Helpers

    static func format(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }

    /// Sizes that scale with the bar's height.
    struct Metrics {
        let size: CGSize
        var padding: CGFloat { (size.height * 0.13).rounded() }
        var titleSize: CGFloat { min(22, max(12, size.height * 0.19)) }
        var detailSize: CGFloat { titleSize * 0.8 }
        var timeSize: CGFloat { min(14, max(10, size.height * 0.14)) }
        var timeWidth: CGFloat { timeSize * 3 }
        var iconSize: CGFloat { min(22, max(11, size.height * 0.19)) }
        var controlSpacing: CGFloat { iconSize * 0.55 }
    }
}

// MARK: - Controls

struct ControlButton: View {
    let symbol: String
    let size: CGFloat
    var isOn: Bool?
    let help: String
    let action: () -> Void

    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: symbol)
                    .font(.system(size: size, weight: .semibold))
                    .frame(width: size * 1.7, height: size * 1.5)
                    .contentTransition(.symbolEffect(.replace))
            }
            .foregroundStyle(foreground)
            .background {
                Circle()
                    .fill(.white.opacity(hovering ? 0.12 : 0))
                    .frame(width: size * 1.9, height: size * 1.9)
            }
            .overlay(alignment: .bottom) {
                if isOn == true {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 3.5, height: 3.5)
                        .offset(y: size * 0.35)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }

    private var foreground: Color {
        switch isOn {
        case .some(true): return .accentColor
        case .some(false): return .white.opacity(0.55)
        case .none: return .white.opacity(0.92)
        }
    }
}

/// A thin progress bar you can click or drag to seek, which thickens under the pointer.
struct Scrubber: View {
    let progress: Double
    let enabled: Bool
    let onScrub: (Double) -> Void
    let onCommit: (Double) -> Void

    @ViewState private var hovering = false
    @ViewState private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let active = enabled && (hovering || dragging)
            let thickness: CGFloat = active ? 6 : 4
            let fraction = min(1, max(0, progress))
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.2))
                Capsule().fill(Color.accentColor)
                    .frame(width: max(thickness, width * fraction))
                    .opacity(fraction > 0 ? 1 : 0)
                if active {
                    Circle().fill(.white)
                        .frame(width: 12, height: 12)
                        .shadow(color: .black.opacity(0.3), radius: 2)
                        .offset(x: width * fraction - 6)
                }
            }
            .frame(height: thickness)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard enabled, width > 0 else { return }
                        dragging = true
                        onScrub(min(1, max(0, value.location.x / width)))
                    }
                    .onEnded { value in
                        guard enabled, width > 0 else { return }
                        dragging = false
                        onCommit(min(1, max(0, value.location.x / width)))
                    }
            )
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: active)
        }
        .frame(height: 16)
    }
}

struct ResizeHandle: View {
    let edge: WindowDragger.Action
    let dragger: WindowDragger?

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { _ in dragger?.drag(edge) }
                    .onEnded { _ in dragger?.end() }
            )
            .onHover { inside in
                let cursor: NSCursor = edge == .bottom ? .resizeUpDown : .resizeLeftRight
                if inside { cursor.push() } else { NSCursor.pop() }
            }
    }
}

/// SwiftUI's plain `State` property wrapper. The Command Line Tools don't ship the plugin behind
/// the newer `@State` macro, so `@State` doesn't compile here. This alias reaches the wrapper itself.
typealias ViewState<Value> = SwiftUI.State<Value>
