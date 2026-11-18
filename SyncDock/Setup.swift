import Foundation

enum FullDiskAccess {
    static let settingsURL =
        URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles")!

    /// A folder only processes with Full Disk Access can list. The background runs are the same
    /// executable as the app, so the app's own access is theirs too.
    static let protectedFolder = "/Library/Application Support/com.apple.TCC"

    static var isGranted: Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: protectedFolder)) != nil
    }
}
