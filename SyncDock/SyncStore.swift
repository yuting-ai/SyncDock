import AppKit
import Observation
import ServiceManagement

@MainActor @Observable
final class SyncStore {
    enum Overall {
        case ok, syncing, attention

        var symbol: String {
            switch self {
            case .ok: "externaldrive.badge.checkmark"
            case .syncing: "arrow.triangle.2.circlepath"
            case .attention: "externaldrive.badge.exclamationmark"
            }
        }
    }

    /// A task whose last log is older than this is flagged as overdue.
    static let staleAfter: TimeInterval = 48 * 3600

    private(set) var tasks: [SyncTask] = []
    /// Latest run per task id.
    private(set) var logs: [String: SyncLog] = [:]
    /// Runs started from SyncDock (task id → start time), cleared when their log appears.
    private(set) var pending: [String: Date] = [:]
    /// Tasks whose sync is running right now, however it was started.
    private(set) var running: Set<String> = []
    private(set) var now = Date.now
    private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    private(set) var lastError: String?
    /// Whether SyncDock has Full Disk Access, which its background runs need.
    private(set) var hasFullDiskAccess = FullDiskAccess.isGranted

    /// Set for layout snapshots, so they don't depend on the permissions of whoever renders them.
    private var accessOverride: Bool?
    /// Whether this store manages the real tasks (not a snapshot or SYNCDOCK_HOME test data).
    private let managesAgents: Bool
    private var migrationChecked = false
    private var timer: Timer?
    private var watcher: DispatchSourceFileSystemObject?

    init(watch: Bool = true) {
        managesAgents = watch && !Paths.isTestHome
        if managesAgents { TaskFiles.repairAgents(TaskLoader.loadTasks()) }
        refresh()
        if watch { startWatching() }
    }

    var overall: Overall {
        if !pending.isEmpty || !running.isEmpty { return .syncing }
        return tasks.contains(where: needsAttention) ? .attention : .ok
    }

    func isRunning(_ task: SyncTask) -> Bool { pending[task.id] != nil || running.contains(task.id) }

    /// Only scheduled tasks can fall behind; manual ones run when the user says so.
    func isStale(_ task: SyncTask) -> Bool {
        guard task.schedule.kind != .manual else { return false }
        guard let log = logs[task.id] else { return true }
        return now.timeIntervalSince(log.date) > Self.staleAfter
    }

    func needsAttention(_ task: SyncTask) -> Bool {
        isStale(task) || (logs[task.id].map { $0.result != .success } ?? false)
    }

    func refresh() {
        now = .now
        tasks = TaskLoader.loadTasks(now: now)
        logs = LogReader.latestLogs()
        running = Set(tasks.map(\.id).filter(RunLock.isHeld))
        checkSetup()

        // Log files are named after the run's start time, so a log at or after the kickstart (minus
        // clock slack) belongs to our run. A run that never took its lock was skipped (drive unplugged).
        for task in tasks {
            guard let started = pending[task.id] else { continue }
            let finished = logs[task.id].map { $0.date >= started.addingTimeInterval(-2) } ?? false
            let neverStarted = !running.contains(task.id) && now.timeIntervalSince(started) > 10
            if finished || neverStarted { pending[task.id] = nil }
        }
    }

    /// Runs the job right away. A missing target folder is created first: when the user starts a run
    /// themselves that's expected, so it shouldn't be flagged. Scheduled runs still warn, since a
    /// backup folder vanishing unattended is worth knowing about.
    func runNow(_ task: SyncTask) {
        guard !isRunning(task), !task.isVolumeMissing else { return }
        try? Self.createFolderIfMissing(task.targetPath)
        if LaunchAgent.kickstart(label: task.label) {
            pending[task.id] = .now
            lastError = nil
            // Picks up the run's lock shortly after it starts.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                MainActor.assumeIsolated { self?.refresh() }
            }
        } else {
            lastError = String(localized: "无法启动 \(task.name)")
        }
    }

    // MARK: Setup

    var setupComplete: Bool { hasFullDiskAccess }

    func checkSetup() {
        hasFullDiskAccess = accessOverride ?? FullDiskAccess.isGranted
        migrateIfReady()
    }

    /// Moves SyncDock 1.x tasks (run by FreeFileSync) to the built-in engine, once SyncDock has the
    /// access to run them. Until then FreeFileSync keeps running them, so no backup is missed.
    private func migrateIfReady() {
        guard managesAgents, hasFullDiskAccess, !migrationChecked else { return }
        migrationChecked = true
        if !LegacyImport.run().isEmpty { tasks = TaskLoader.loadTasks(now: now) }
    }

    /// Forces a setup state for layout snapshots.
    func previewSetup(granted: Bool) {
        accessOverride = granted
        hasFullDiskAccess = granted
    }

    // MARK: Editing

    /// The task being edited in the editor sheet.
    var draft = TaskDraft()
    /// Whether the main window shows the editor sheet for `draft`.
    var isEditing = false

    func beginNewTask() {
        draft = TaskDraft()
        isEditing = true
    }

    func beginEditing(_ task: SyncTask) {
        draft = task.draft
        selectedTaskID = task.id
        isEditing = true
    }

    func validationError() -> String? {
        draft.validationError(existing: tasks)
    }

    /// Saves the task and (re)loads its launch agent. Returns the saved task.
    @discardableResult
    func saveDraft() throws -> SyncTask {
        let task = draft.task(id: draft.id ?? SyncTask.newID())
        // Create the destination up front so the first run doesn't warn about a missing folder.
        try Self.createFolderIfMissing(task.targetPath)
        try TaskFiles.save(task)
        draft.id = task.id
        selectedTaskID = task.id
        refresh()
        return task
    }

    func delete(_ task: SyncTask) {
        TaskFiles.delete(task)
        pending[task.id] = nil
        refresh()
    }

    func runNow(id: String) {
        if let task = tasks.first(where: { $0.id == id }) { runNow(task) }
    }

    /// Starts every task that isn't running and whose drive is connected.
    func runAll() {
        for task in tasks where !isRunning(task) && !task.isVolumeMissing { runNow(task) }
    }

    /// Creates `path` when only its last component is missing. Deeper gaps (e.g. an unplugged
    /// drive's mount point) are left alone so nothing gets written onto the internal disk.
    private static func createFolderIfMissing(_ path: String) throws {
        let fm = FileManager.default
        let url = URL(filePath: path)
        guard !path.isEmpty, !fm.fileExists(atPath: path),
              fm.fileExists(atPath: url.deletingLastPathComponent().folderPath) else { return }
        try fm.createDirectory(at: url, withIntermediateDirectories: false)
    }

    /// The task selected in the main window.
    var selectedTaskID: String?

    var selectedTask: SyncTask? {
        tasks.first { $0.id == selectedTaskID } ?? tasks.first
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            lastError = nil
        } catch {
            lastError = String(localized: "无法更改登录项：\(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func startWatching() {
        // New log files appear when a run finishes; refresh right away.
        try? FileManager.default.createDirectory(at: Paths.logs, withIntermediateDirectories: true)
        let fd = open(Paths.logs.path(percentEncoded: false), O_EVTONLY)
        if fd >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.refresh() }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            watcher = source
        }
        // Keeps relative times, volume state, running syncs and permissions current.
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
