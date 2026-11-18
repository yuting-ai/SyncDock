import Foundation

/// Saving and removing tasks: the task file plus the launch agent that runs it on schedule.
enum TaskFiles {
    static func save(_ task: SyncTask) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: Paths.tasks, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(task).write(to: TaskLoader.url(for: task.id), options: .atomic)
        try LaunchAgent.install(task)
    }

    /// Unloads the task and moves its task file and launch agent to the Trash; its logs are removed.
    static func delete(_ task: SyncTask) {
        let fm = FileManager.default
        LaunchAgent.uninstall(label: task.label)
        try? fm.trashItem(at: TaskLoader.url(for: task.id), resultingItemURL: nil)
        try? fm.removeItem(at: Paths.tasks.appending(path: task.id + ".lock"))
        for url in LogReader.records()[task.id] ?? [] { LogReader.remove(url) }
    }

    /// Reinstalls launch agents that are missing or run a different copy of SyncDock (the app was
    /// moved, or a development build saved them). Development builds only fix agents that can't run.
    static func repairAgents(_ tasks: [SyncTask]) {
        let current = Bundle.main.executablePath
        for task in tasks {
            let url = LaunchAgent.url(for: task.label)
            let program = (NSDictionary(contentsOf: url)?["ProgramArguments"] as? [String])?.first
            #if DEBUG
            let broken = program.map { !FileManager.default.isExecutableFile(atPath: $0) } ?? true
            #else
            let broken = program == nil || program != current
            #endif
            if broken { try? LaunchAgent.install(task) }
        }
    }
}

/// Lock held by a running sync, so the same task never runs twice at once and the app can tell it's running.
enum RunLock {
    static func url(for id: String) -> URL {
        Paths.tasks.appending(path: id + ".lock")
    }

    /// Takes the lock, returning its file descriptor, or nil when the task is already running.
    /// The app's `isHeld` check holds the lock for an instant, so a busy lock is retried briefly
    /// before concluding another run has it.
    static func acquire(id: String) -> Int32? {
        try? FileManager.default.createDirectory(at: Paths.tasks, withIntermediateDirectories: true)
        let fd = open(url(for: id).path(percentEncoded: false), O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return nil }
        for _ in 0..<20 {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { return fd }
            usleep(100_000)
        }
        close(fd)
        return nil
    }

    static func isHeld(id: String) -> Bool {
        let fd = open(url(for: id).path(percentEncoded: false), O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard flock(fd, LOCK_SH | LOCK_NB) == 0 else { return true }
        flock(fd, LOCK_UN)
        return false
    }
}

/// The launch agent that runs SyncDock's own executable as `SyncDock --run <task id>`.
enum LaunchAgent {
    static func url(for label: String) -> URL {
        Paths.launchAgents.appending(path: label + ".plist")
    }

    static func plist(for task: SyncTask) -> [String: Any] {
        var plist: [String: Any] = [
            "Label": task.label,
            "ProgramArguments": [Bundle.main.executablePath ?? CommandLine.arguments[0], "--run", task.id],
            "StandardErrorPath": Paths.support.appending(path: "launchd-error.log").path(percentEncoded: false),
        ]
        plist["StartCalendarInterval"] = task.schedule.plistValue
        return plist
    }

    /// Writes the agent and (re)loads it so launchd picks up the new schedule.
    static func install(_ task: SyncTask) throws {
        guard !Paths.isTestHome else { return }
        try FileManager.default.createDirectory(at: Paths.launchAgents, withIntermediateDirectories: true)
        let url = url(for: task.label)
        let data = try PropertyListSerialization.data(fromPropertyList: plist(for: task), format: .xml, options: 0)
        try data.write(to: url, options: .atomic)
        try reload(label: task.label, agentURL: url)
    }

    static func uninstall(label: String) {
        guard !Paths.isTestHome else { return }
        launchctl("bootout", "gui/\(getuid())/\(label)")
        try? FileManager.default.trashItem(at: url(for: label), resultingItemURL: nil)
    }

    static func reload(label: String, agentURL: URL) throws {
        let domain = "gui/\(getuid())"
        launchctl("bootout", "\(domain)/\(label)")
        // bootout finishes asynchronously; bootstrap fails with EIO until it has.
        for _ in 0..<20 {
            if launchctl("bootstrap", domain, agentURL.path(percentEncoded: false)) == 0 { return }
            Thread.sleep(forTimeInterval: 0.15)
        }
        throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: String(localized: "无法加载定时任务 \(label)")])
    }

    static func kickstart(label: String) -> Bool {
        launchctl("kickstart", "gui/\(getuid())/\(label)") == 0
    }

    @discardableResult
    static func launchctl(_ args: String...) -> Int32 {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/launchctl")
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}
