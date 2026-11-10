import AppKit
import Combine
import SwiftUI

/// A borderless panel that never takes keyboard focus, so clicking the bar's buttons leaves
/// whatever you were typing in active.
final class BarPanel: NSPanel {
    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false // BarView moves the window itself, so dragging the scrubber never drags the bar.
        isReleasedWhenClosed = false
        animationBehavior = .none
        appearance = NSAppearance(named: .darkAqua)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Lets a click land on a button even though NowBar is never the active app.
final class BarHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Moves and resizes the bar from SwiftUI drag gestures, using the pointer's screen position so
/// the maths doesn't shift as the window moves under it.
@MainActor
final class WindowDragger {
    enum Action { case move, left, right, bottom }

    static let minSize = NSSize(width: 360, height: 52)
    static let maxHeight: CGFloat = 180

    weak var window: NSWindow?
    var onFinish: (() -> Void)?

    private var action: Action?
    private var startMouse = NSPoint.zero
    private var startFrame = NSRect.zero

    func drag(_ requested: Action) {
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        if action == nil {
            action = requested
            startMouse = mouse
            startFrame = window.frame
        }
        let dx = mouse.x - startMouse.x
        let dy = mouse.y - startMouse.y
        var frame = startFrame
        switch action! {
        case .move:
            frame.origin.x += dx
            frame.origin.y += dy
        case .left:
            frame.size.width = max(Self.minSize.width, startFrame.width - dx)
            frame.origin.x = startFrame.maxX - frame.width
        case .right:
            frame.size.width = max(Self.minSize.width, startFrame.width + dx)
        case .bottom:
            frame.size.height = min(Self.maxHeight, max(Self.minSize.height, startFrame.height - dy))
            frame.origin.y = startFrame.maxY - frame.height
        }
        window.setFrame(frame, display: true)
    }

    func end() {
        guard action != nil else { return }
        action = nil
        window?.invalidateShadow()
        onFinish?()
    }
}

/// Owns the bar window: where it sits, which desktops it's on, and whether it's showing.
@MainActor
final class BarController {
    let panel: BarPanel
    let client: SpotifyClient
    let settings: Settings
    private let dragger = WindowDragger()
    private var subscriptions = Set<AnyCancellable>()
    private(set) var isShowing = false

    init(client: SpotifyClient, settings: Settings) {
        self.client = client
        self.settings = settings
        panel = BarPanel(frame: settings.frame ?? Self.defaultFrame())

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = Self.roundedMask(radius: BarView.cornerRadius)
        panel.contentView = effect

        dragger.window = panel
        dragger.onFinish = { [weak self] in self?.saveFrame() }
        let hosting = BarHostingView(rootView: BarView(client: client, settings: settings, dragger: dragger))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor)
        ])

        ensureOnScreen()
        applyPlacement()

        // Order the bar in straight away, even if it starts invisible, so it belongs to the desktop
        // that's active now. Hiding it later only fades it out, which keeps it on that desktop.
        panel.alphaValue = 0
        panel.ignoresMouseEvents = true
        panel.orderFrontRegardless()

        client.$isRunning.combineLatest(settings.$showBar)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] running, show in self?.setShowing(running && show) }
            .store(in: &subscriptions)
        settings.$onTop.combineLatest(settings.$allDesktops)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.applyPlacement() }
            .store(in: &subscriptions)
    }

    // MARK: - Showing

    private func setShowing(_ show: Bool) {
        guard show != isShowing else { return }
        isShowing = show
        client.isActive = show
        panel.ignoresMouseEvents = !show
        if !panel.isVisible { panel.orderFrontRegardless() }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            panel.animator().alphaValue = show ? 1 : 0
        }
    }

    // MARK: - Placement

    /// Window level and desktop (Space) behaviour from the settings.
    func applyPlacement() {
        var behavior: NSWindow.CollectionBehavior = [.ignoresCycle, .fullScreenNone]
        if settings.onTop {
            panel.level = .floating
        } else {
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            behavior.insert(.stationary) // Stays put when you swipe to show the desktop.
        }
        if settings.allDesktops { behavior.insert(.canJoinAllSpaces) }
        panel.collectionBehavior = behavior
        if !settings.onTop { panel.orderBack(nil) }
    }

    /// Re-homes the bar on the desktop you're looking at. A window that's ordered out and back in
    /// joins the active desktop.
    func moveToCurrentDesktop() {
        guard !settings.allDesktops else { return }
        panel.orderOut(nil)
        panel.orderFrontRegardless()
    }

    /// Puts the bar back under the menu bar of the screen with the pointer, at the default size.
    func resetFrame() {
        panel.setFrame(Self.defaultFrame(), display: true)
        panel.invalidateShadow()
        saveFrame()
    }

    /// Brings the bar back if its screen has been unplugged.
    func ensureOnScreen() {
        let frame = panel.frame
        let visible = NSScreen.screens.contains { $0.visibleFrame.intersection(frame).width >= 80 }
        if !visible { resetFrame() }
    }

    private func saveFrame() {
        settings.frame = panel.frame
    }

    static func defaultFrame() -> NSRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let height: CGFloat = 84
        let width = min(1400, visible.width - 48)
        return NSRect(x: (visible.midX - width / 2).rounded(), y: visible.maxY - height - 10, width: width, height: height)
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
