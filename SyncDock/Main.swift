import Foundation

@main
enum Main {
    /// `--snapshot` renders a view to a file and quits; it must not touch the user's tasks.
    static let isSnapshot = CommandLine.arguments.contains("--snapshot")

    static func main() {
        // Launch agents start the same executable to run one sync in the background.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--run"), i + 1 < args.count {
            exit(SyncRunner.run(id: args[i + 1]))
        }
        SyncDockApp.main()
    }
}
