import AppKit

@main
@MainActor
enum NowBarApp {
    static func main() {
        if DebugModes.run(CommandLine.arguments) { return }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
