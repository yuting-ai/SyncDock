import Foundation

/// `SyncDock --run <task id>`: what the launch agent starts. Runs one sync without any UI, writes its
/// logs and exits. The menu bar app doesn't need to be open.
enum SyncRunner {
    /// Runs kept per task; older logs are removed.
    static let keptRuns = 30

    static func run(id: String) -> Int32 {
        guard let task = TaskLoader.load(id: id) else {
            FileHandle.standardError.write(Data("SyncDock: no task \(id)\n".utf8))
            return 1
        }
        if task.isVolumeMissing {
            notify(title: "SyncDock: \(task.name)", message: String(localized: "移动硬盘未连接，本次同步已跳过"))
            return 0
        }
        guard let lock = RunLock.acquire(id: id) else { return 0 }  // already running
        defer { close(lock) }

        // Without Full Disk Access, reading the Desktop or a drive asks for permission in a prompt that
        // nobody may be there to answer, and the run would hang on it. Report the problem instead.
        // (Test runs with SYNCDOCK_HOME are started from a terminal, whose access is what counts then.)
        if !Paths.isTestHome && !FullDiskAccess.isGranted {
            let now = Date.now
            let message = String(localized: "SyncDock 没有完全磁盘访问权限，无法同步。请在「系统设置 › 隐私与安全性 › 完全磁盘访问权限」里打开 SyncDock 的开关；如果已经打开，先关掉再重新打开。")
            write(RunRecord(start: now, end: now, result: .error, items: 0, bytes: 0, errors: [message], warnings: [],
                            counts: [:], source: task.sourcePath, target: task.targetPath, mode: task.mode),
                  changes: [], id: task.id)
            prune(id: id)
            notify(title: "SyncDock: \(task.name)", message: String(localized: "没有完全磁盘访问权限，本次同步没有运行"))
            return 1
        }

        // launchd sends SIGTERM when the agent is unloaded (e.g. the task is edited mid-run).
        let cancellation = Cancellation()
        signal(SIGTERM, SIG_IGN)
        let signalSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        signalSource.setEventHandler { cancellation.set() }
        signalSource.resume()

        let start = Date.now
        let options = SyncEngine.Options(source: URL(filePath: task.sourcePath), target: URL(filePath: task.targetPath),
                                         mode: task.mode, excludeHidden: task.excludeHidden,
                                         includeGit: task.includeGit, excludes: task.excludes,
                                         deletePermanently: task.deletesPermanently)
        let outcome = SyncEngine(options: options, cancelled: cancellation).run()
        var counts: [String: Int] = [:]
        for change in outcome.changes { counts[change.kind.rawValue, default: 0] += 1 }
        let record = RunRecord(start: start, end: .now, result: outcome.result, items: outcome.items,
                               bytes: outcome.bytes, errors: outcome.errors, warnings: outcome.warnings,
                               counts: counts, source: task.sourcePath, target: task.targetPath, mode: task.mode)
        write(record, changes: outcome.changes, id: task.id)
        prune(id: id)

        if outcome.result == .error {
            notify(title: "SyncDock: \(task.name)",
                   message: String(localized: "同步出错（\(outcome.errors.count) 个错误），点菜单栏里的任务查看详情"))
        }
        return 0
    }

    private static func write(_ record: RunRecord, changes: [Change], id: String) {
        try? FileManager.default.createDirectory(at: Paths.logs, withIntermediateDirectories: true)
        let url = Paths.logs.appending(path: LogReader.baseName(id: id, start: record.start) + ".json")
        let list = ChangeList(changes: Array(changes.prefix(ChangeList.limit)),
                              omitted: max(0, changes.count - ChangeList.limit))
        if let data = try? LogReader.encoder.encode(list) {
            try? data.write(to: LogReader.changesURL(for: url), options: .atomic)
        }
        // The record goes last: its appearance is how the app learns the run has finished.
        if let data = try? LogReader.encoder.encode(record) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func prune(id: String) {
        let records = LogReader.records()[id] ?? []
        for url in records.dropLast(keptRuns) { LogReader.remove(url) }
    }

    /// A notification from a background process with no app UI of its own.
    static func notify(title: String, message: String) {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/osascript")
        process.arguments = ["-e", "on run argv", "-e", "display notification (item 1 of argv) with title (item 2 of argv)",
                             "-e", "end run", message, title]
        try? process.run()
        process.waitUntilExit()
    }
}
