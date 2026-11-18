import Foundation

enum SyncMode: String, CaseIterable, Identifiable, Codable {
    /// Copy new and changed files to the target, never delete there.
    case update
    /// Make the target identical to the source, deleting extra files.
    case mirror

    var id: Self { self }
}

/// When launchd starts a job. Weekdays use launchd numbering: 1 = Monday … 7 = Sunday.
struct Schedule: Equatable, Codable {
    enum Kind: String, CaseIterable, Identifiable, Codable {
        case manual, daily, weekly
        var id: Self { self }
    }

    var kind: Kind = .daily
    var hour = 21
    var minute = 0
    var weekdays: Set<Int> = [7]

    init() {}

    /// Parses a `StartCalendarInterval` value (missing, one dict, or an array of dicts).
    init(plistValue: Any?) {
        let entries: [[String: Int]] = switch plistValue {
        case let dict as [String: Int]: [dict]
        case let array as [[String: Int]]: array
        default: []
        }
        guard let first = entries.first else {
            kind = .manual
            return
        }
        hour = first["Hour"] ?? 0
        minute = first["Minute"] ?? 0
        let days = entries.compactMap { $0["Weekday"] }.map { $0 == 0 ? 7 : $0 }
        if days.isEmpty {
            kind = .daily
        } else {
            kind = .weekly
            weekdays = Set(days)
        }
    }

    /// The `StartCalendarInterval` value, or nil for manual-only jobs.
    var plistValue: Any? {
        switch kind {
        case .manual: nil
        case .daily: ["Hour": hour, "Minute": minute]
        case .weekly: weekdays.sorted().map { ["Weekday": $0, "Hour": hour, "Minute": minute] }
        }
    }

    func nextRun(after date: Date) -> Date? {
        let cal = Calendar.current
        switch kind {
        case .manual:
            return nil
        case .daily:
            return cal.nextDate(after: date, matching: DateComponents(hour: hour, minute: minute),
                                matchingPolicy: .nextTime)
        case .weekly:
            // Calendar weekdays start at Sunday = 1.
            return weekdays.compactMap { day in
                cal.nextDate(after: date,
                             matching: DateComponents(hour: hour, minute: minute, weekday: day % 7 + 1),
                             matchingPolicy: .nextTime)
            }.min()
        }
    }
}

/// A sync task, stored as `Tasks/<id>.json` and run by the launch agent `<labelPrefix><id>`.
struct SyncTask: Identifiable, Equatable, Codable {
    var id: String
    var name: String
    var sourcePath: String
    /// The folder the user picked; see `targetPath` for where files actually go.
    var targetFolder: String
    /// Sync into `targetFolder/<source folder name>` instead of straight into `targetFolder`.
    var createSubfolder: Bool
    var mode: SyncMode
    var excludeHidden: Bool
    var includeGit: Bool
    var schedule: Schedule

    static func newID() -> String {
        "task-" + UUID().uuidString.prefix(8).lowercased()
    }

    var label: String { Paths.labelPrefix + id }

    /// The folder files are written into.
    var targetPath: String {
        Self.effectiveTarget(source: sourcePath, target: targetFolder, createSubfolder: createSubfolder)
    }

    var source: String { TaskLoader.shorten(sourcePath) }
    var target: String { TaskLoader.shorten(targetPath) }

    /// Volume that must be mounted for the job to run (nil for local/cloud targets).
    var requiredVolume: String? {
        Self.requiredVolume(source: sourcePath, target: targetPath)
    }

    var isVolumeMissing: Bool {
        // Snapshots show demo tasks on made-up drives as connected.
        guard let requiredVolume, !Main.isSnapshot else { return false }
        return !FileManager.default.fileExists(atPath: requiredVolume)
    }

    /// Cloud folders refuse moving files to the Trash, so deletions there are permanent.
    var deletesPermanently: Bool {
        targetPath.contains("/Library/CloudStorage/")
    }

    func nextRun(after date: Date = .now) -> Date? {
        schedule.nextRun(after: date)
    }

    var draft: TaskDraft {
        TaskDraft(id: id, name: name, source: sourcePath, target: targetFolder, createSubfolder: createSubfolder,
                  mode: mode, excludeHidden: excludeHidden, includeGit: includeGit, schedule: schedule)
    }

    static func effectiveTarget(source: String, target: String, createSubfolder: Bool) -> String {
        guard createSubfolder, !source.isEmpty, !target.isEmpty else { return target }
        return URL(filePath: target).appending(path: URL(filePath: source).lastPathComponent).folderPath
    }

    /// The mount point a task depends on: the target's volume, else the source's.
    static func requiredVolume(source: String, target: String) -> String? {
        for path in [target, source] {
            let parts = path.split(separator: "/", omittingEmptySubsequences: true)
            if parts.count >= 2, parts[0] == "Volumes" { return "/Volumes/\(parts[1])" }
        }
        return nil
    }
}

/// The editable fields of a task, as shown in the editor.
struct TaskDraft: Equatable {
    /// nil for a task that does not exist yet.
    var id: String?
    var name = ""
    var source = ""
    /// The folder the user picked; see `effectiveTarget` for where files actually go.
    var target = ""
    var createSubfolder = true
    var mode: SyncMode = .update
    var excludeHidden = true
    var includeGit = false
    var schedule = Schedule()

    var isNew: Bool { id == nil }

    var sourceFolderName: String { URL(filePath: source).lastPathComponent }

    var effectiveTarget: String {
        SyncTask.effectiveTarget(source: source, target: target, createSubfolder: createSubfolder)
    }

    var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    func task(id: String) -> SyncTask {
        SyncTask(id: id, name: trimmedName, sourcePath: source, targetFolder: target,
                 createSubfolder: createSubfolder, mode: mode, excludeHidden: excludeHidden,
                 includeGit: includeGit, schedule: schedule)
    }

    /// A message describing what still needs fixing, or nil when the draft can be saved.
    func validationError(existing: [SyncTask]) -> String? {
        if trimmedName.isEmpty { return String(localized: "请填写任务名称") }
        if source.isEmpty { return String(localized: "请选择源文件夹") }
        if target.isEmpty { return String(localized: "请选择目标文件夹") }
        let s = URL(filePath: source).standardizedFileURL.path(percentEncoded: false)
        let t = URL(filePath: effectiveTarget).standardizedFileURL.path(percentEncoded: false)
        if s == t { return String(localized: "源文件夹和目标文件夹不能相同") }
        if t.hasPrefix(s.hasSuffix("/") ? s : s + "/") { return String(localized: "目标文件夹不能放在源文件夹里面") }
        if s.hasPrefix(t.hasSuffix("/") ? t : t + "/") { return String(localized: "源文件夹不能放在目标文件夹里面") }
        if schedule.kind == .weekly && schedule.weekdays.isEmpty { return String(localized: "请至少选择一天") }
        let normalized = trimmedName.precomposedStringWithCanonicalMapping.lowercased()
        let clash = existing.contains {
            $0.id != id && $0.name.precomposedStringWithCanonicalMapping.lowercased() == normalized
        }
        if clash { return String(localized: "已经有同名的任务了") }
        return nil
    }
}

extension URL {
    /// The path without the trailing slash Foundation adds to directory URLs ("/" stays "/").
    var folderPath: String {
        let path = path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}

/// The result of the latest run of a task.
struct SyncLog: Equatable {
    enum Result: String, Codable { case success, warning, error }

    /// The run's record file.
    let url: URL
    let date: Date
    var result: Result
    /// e.g. "75 项 · 1.64 GB", nil when the run copied nothing countable.
    var summary: String?
}

/// One change a run made in the target.
struct Change: Codable, Hashable {
    enum Kind: String, Codable, CaseIterable {
        case added, updated, folder, renamed, trashed, deleted
    }

    var kind: Kind
    /// Relative to the target folder.
    var path: String
    /// The previous name, for renames.
    var from: String?
    var isFolder: Bool?
    var bytes: Int64?
}

/// A run's full list of changes, saved as `<id> <start>.changes.json` and read only when shown.
struct ChangeList: Codable {
    static let limit = 5000

    var changes: [Change]
    /// Changes beyond `limit`, counted but not listed.
    var omitted: Int
}

/// What a run did, saved as `<id> <start>.json`.
struct RunRecord: Codable, Equatable {
    var start: Date
    var end: Date
    var result: SyncLog.Result
    var items: Int
    var bytes: Int64
    var errors: [String]
    var warnings: [String]
    /// Changes per `Change.Kind` raw value.
    var counts: [String: Int]?
    var source: String?
    var target: String?
    var mode: SyncMode?

    func count(_ kinds: Change.Kind...) -> Int {
        kinds.reduce(0) { $0 + (counts?[$1.rawValue] ?? 0) }
    }

    var duration: TimeInterval { end.timeIntervalSince(start) }

    /// e.g. "75 项 · 1.64 GB", or "无变化" when nothing was changed.
    var summary: String {
        if items == 0 { return String(localized: "无变化") }
        var parts = [String(localized: "\(items) 项")]
        if bytes > 0 { parts.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) }
        return parts.joined(separator: " · ")
    }
}

/// A run in a task's history.
struct RunEntry: Identifiable, Equatable {
    let url: URL
    let record: RunRecord
    var id: URL { url }

    var changesURL: URL { LogReader.changesURL(for: url) }
}

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    /// `SYNCDOCK_HOME` overrides where tasks and logs are kept, for screenshots and tests.
    static let support = ProcessInfo.processInfo.environment["SYNCDOCK_HOME"].map { URL(filePath: $0) }
        ?? home.appending(path: "Library/Application Support/SyncDock")
    /// Demo or test data: launch agents, which are shared with the real tasks, are left alone.
    static let isTestHome = ProcessInfo.processInfo.environment["SYNCDOCK_HOME"] != nil
    static let tasks = support.appending(path: "Tasks")
    static let logs = support.appending(path: "Logs")
    static let launchAgents = home.appending(path: "Library/LaunchAgents")
    static let labelPrefix = "me.lepton.syncdock."
}

enum TaskLoader {
    static func loadTasks(now: Date = .now) -> [SyncTask] {
        let files = (try? FileManager.default.contentsOfDirectory(at: Paths.tasks, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(SyncTask.self, from: Data(contentsOf: $0)) }
            .sorted {
                // Soonest scheduled first, then manual-only jobs by name.
                let (a, b) = ($0.nextRun(after: now) ?? .distantFuture, $1.nextRun(after: now) ?? .distantFuture)
                return a != b ? a < b : $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    static func load(id: String) -> SyncTask? {
        try? JSONDecoder().decode(SyncTask.self, from: Data(contentsOf: url(for: id)))
    }

    static func url(for id: String) -> URL {
        Paths.tasks.appending(path: id + ".json")
    }

    /// Makes paths readable: "桌面/Mphil", "SSD-BAI/BityDev/BityDev", "OneDrive-Curtin/…/Mphil".
    static func shorten(_ path: String) -> String {
        let home = Paths.home.path(percentEncoded: false)
        var p = path
        let desktop = FileManager.default.displayName(atPath: home + "Desktop")
        for (prefix, replacement) in [(home + "Library/CloudStorage/", ""), ("/Volumes/", ""),
                                      (home + "Desktop/", desktop + "/"), (home, "~/")] where p.hasPrefix(prefix) {
            p = replacement + p.dropFirst(prefix.count)
            break
        }
        let parts = p.split(separator: "/")
        return parts.count > 3 ? "\(parts.first!)/…/\(parts.last!)" : p
    }
}

/// Run logs: `<id> <yyyy-MM-dd HHmmss.SSS>.json` (a `RunRecord`) and `.changes.json` (a `ChangeList`),
/// written when a run ends.
enum LogReader {
    private static let pattern = /^(task-[0-9a-z-]+) (\d{4}-\d{2}-\d{2} \d{6}\.\d{3})\.json$/

    static let fileDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HHmmss.SSS"
        return f
    }()

    static func baseName(id: String, start: Date) -> String {
        "\(id) \(fileDate.string(from: start))"
    }

    static func changesURL(for recordURL: URL) -> URL {
        recordURL.deletingPathExtension().appendingPathExtension("changes.json")
    }

    /// Record files per task id, oldest first.
    static func records() -> [String: [URL]] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: Paths.logs.path(percentEncoded: false))) ?? []
        var result: [String: [URL]] = [:]
        for file in files.sorted() {
            guard let match = try? pattern.wholeMatch(in: file) else { continue }
            result[String(match.1), default: []].append(Paths.logs.appending(path: file))
        }
        return result
    }

    static func record(at url: URL) -> RunRecord? {
        try? decoder.decode(RunRecord.self, from: Data(contentsOf: url))
    }

    /// The latest run per task id.
    static func latestLogs() -> [String: SyncLog] {
        var result: [String: SyncLog] = [:]
        for (id, urls) in records() {
            guard let url = urls.last, let record = record(at: url) else { continue }
            result[id] = SyncLog(url: url, date: record.start, result: record.result, summary: record.summary)
        }
        return result
    }

    /// A task's runs, newest first.
    static func runs(for id: String) -> [RunEntry] {
        (records()[id] ?? []).reversed().compactMap { url in record(at: url).map { RunEntry(url: url, record: $0) } }
    }

    static func changes(for run: RunEntry) -> ChangeList? {
        try? decoder.decode(ChangeList.self, from: Data(contentsOf: run.changesURL))
    }

    /// Removes a run's files.
    static func remove(_ recordURL: URL) {
        try? FileManager.default.removeItem(at: recordURL)
        try? FileManager.default.removeItem(at: changesURL(for: recordURL))
    }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()
}
