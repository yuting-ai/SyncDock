import SwiftUI

/// The sync history window: tasks on the left; the selected task's recent runs and what each one did on the right.
struct HistoryView: View {
    @Bindable var store: SyncStore
    @Environment(\.openWindow) private var openWindow
    @State private var runs: [RunEntry] = []
    @State private var selectedRunID: URL?
    @State private var loaded: LoadedChanges?

    struct LoadedChanges {
        let url: URL
        let list: ChangeList?
    }

    /// `preload` reads the history right away instead of in a task, for layout snapshots.
    init(store: SyncStore, preload: Bool = false) {
        _store = Bindable(wrappedValue: store)
        if preload, let id = store.historyTaskID ?? store.tasks.first?.id {
            let runs = LogReader.runs(for: id)
            _runs = State(initialValue: runs)
            _selectedRunID = State(initialValue: runs.first?.url)
            _loaded = State(initialValue: runs.first.map { LoadedChanges(url: $0.url, list: LogReader.changes(for: $0)) })
        }
    }

    private var task: SyncTask? {
        store.tasks.first { $0.id == store.historyTaskID } ?? store.tasks.first
    }

    private var selectedRun: RunEntry? {
        runs.first { $0.url == selectedRunID }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 230)
            Divider()
            Group {
                if let task {
                    detail(task)
                } else {
                    ContentUnavailableView("还没有同步任务", systemImage: "externaldrive.badge.plus",
                                           description: Text("在菜单栏里点 ＋ 新建一个同步任务。"))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 860, minHeight: 560)
        .navigationTitle("同步记录")
        .task(id: ReloadKey(taskID: task?.id, latest: task.flatMap { store.logs[$0.id]?.date })) {
            await reloadRuns()
        }
        .task(id: selectedRunID) {
            await loadChanges()
        }
    }

    private struct ReloadKey: Equatable {
        let taskID: String?
        let latest: Date?
    }

    // MARK: Sidebar

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                Text("任务")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)
                ForEach(store.tasks) { item in
                    SidebarRow(task: item, store: store, selected: item.id == task?.id) {
                        store.historyTaskID = item.id
                    }
                }
            }
            .padding(10)
            .padding(.top, 6)
        }
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.5))
    }

    // MARK: Detail

    private func detail(_ task: SyncTask) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            TaskHeader(task: task, store: store) {
                store.beginEditing(task)
                openWindow(id: SyncDockApp.editorID)
                NSApp.activate()
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 14)

            if !runs.isEmpty || store.isRunning(task) {
                RunTimeline(runs: runs, selection: $selectedRunID, isRunning: store.isRunning(task), now: store.now)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 14)
            }

            Divider()

            if let run = selectedRun {
                RunDetail(run: run, changes: loaded?.url == run.url ? .some(loaded?.list) : nil, now: store.now)
            } else {
                ContentUnavailableView("还没有同步记录", systemImage: "clock.arrow.circlepath",
                                       description: Text("任务运行后，每次同步的结果都会显示在这里。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func reloadRuns() async {
        guard let id = task?.id else {
            runs = []
            selectedRunID = nil
            return
        }
        let newRuns = await Task.detached(priority: .userInitiated) { LogReader.runs(for: id) }.value
        let previousNewest = runs.first?.url
        runs = newRuns
        // Follow the newest run unless the user is looking at an older one.
        if selectedRunID == nil || selectedRunID == previousNewest || !newRuns.contains(where: { $0.url == selectedRunID }) {
            selectedRunID = newRuns.first?.url
        }
    }

    private func loadChanges() async {
        guard let run = selectedRun, loaded?.url != run.url else { return }
        let list = await Task.detached(priority: .userInitiated) { LogReader.changes(for: run) }.value
        if selectedRunID == run.url { loaded = LoadedChanges(url: run.url, list: list) }
    }
}

private struct SidebarRow: View {
    let task: SyncTask
    let store: SyncStore
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                TaskStatusIcon(task: task, store: store)
                    .frame(width: 16, height: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.name)
                        .fontWeight(selected ? .semibold : .regular)
                        .lineLimit(1)
                    Group {
                        if let log = store.logs[task.id] {
                            Text(DateText.describe(log.date, now: store.now))
                        } else {
                            Text("还没有同步记录")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(selected ? Color.accentColor.opacity(0.16) : hovering ? Color.primary.opacity(0.05) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Task header

private struct TaskHeader: View {
    let task: SyncTask
    let store: SyncStore
    let onEdit: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(task.name)
                    .font(.title2.weight(.semibold))
                HStack(spacing: 6) {
                    PathLabel(path: task.sourcePath, systemImage: "folder")
                    Image(systemName: "arrow.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                    PathLabel(path: task.targetPath, systemImage: task.requiredVolume == nil ? "folder" : "externaldrive")
                }
                HStack(spacing: 6) {
                    Tag(text: task.mode == .mirror ? String(localized: "镜像") : String(localized: "更新"),
                        systemImage: task.mode == .mirror ? "equal.square" : "arrow.right.square")
                    Tag(text: ScheduleText.describe(task.schedule), systemImage: "calendar")
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                Button(action: onEdit) {
                    Label("编辑", systemImage: "slider.horizontal.3")
                }
                Button {
                    store.runNow(task)
                } label: {
                    Label("立即同步", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.isRunning(task) || task.isVolumeMissing)
                .help(task.isVolumeMissing ? String(localized: "移动硬盘未连接") : String(localized: "立即同步"))
            }
            .controlSize(.large)
        }
    }
}

/// A folder path that opens in Finder when clicked.
private struct PathLabel: View {
    let path: String
    let systemImage: String

    var body: some View {
        Button {
            NSWorkspace.shared.open(URL(filePath: path))
        } label: {
            Label(TaskLoader.shorten(path), systemImage: systemImage)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .buttonStyle(.plain)
        .font(.callout)
        .foregroundStyle(.secondary)
        .help(String(localized: "在 Finder 中打开 \(path)"))
    }
}

private struct Tag: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
    }
}

enum ScheduleText {
    static func describe(_ schedule: Schedule) -> String {
        let time = DateFormatter.localizedString(
            from: Calendar.current.date(from: DateComponents(hour: schedule.hour, minute: schedule.minute)) ?? .now,
            dateStyle: .none, timeStyle: .short)
        switch schedule.kind {
        case .manual:
            return String(localized: "仅手动")
        case .daily:
            return String(localized: "每天 \(time)")
        case .weekly:
            // Schedule weekdays: 1 = Monday … 7 = Sunday; calendar symbols start at Sunday.
            let symbols = Calendar.current.shortStandaloneWeekdaySymbols
            let days = schedule.weekdays.sorted().map { symbols[$0 % 7] }.formatted(.list(type: .and, width: .narrow))
            return String(localized: "每周 \(days) \(time)")
        }
    }
}

// MARK: - Timeline

/// The last runs as bars, oldest on the left, colored by result. Clicking one shows it.
private struct RunTimeline: View {
    let runs: [RunEntry]
    @Binding var selection: URL?
    let isRunning: Bool
    let now: Date

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("最近 \(runs.count) 次")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()

            HStack(alignment: .bottom, spacing: 3) {
                ForEach(runs.reversed()) { run in
                    let selected = run.url == selection
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(ResultStyle(run.record.result).color.gradient)
                        .opacity(selected ? 1 : 0.55)
                        .frame(width: 10, height: selected ? 26 : 18)
                        .overlay {
                            if selected {
                                RoundedRectangle(cornerRadius: 3.5)
                                    .strokeBorder(Color.primary.opacity(0.35), lineWidth: 1)
                                    .padding(-2.5)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { selection = run.url }
                        .help("\(DateText.describe(run.record.start, now: now)) · \(run.record.summary)")
                }
                if isRunning {
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(Color.accentColor.opacity(0.6))
                        .frame(width: 10, height: 18)
                        .phaseAnimator([0.35, 1]) { bar, phase in bar.opacity(phase) }
                        .help(String(localized: "正在同步…"))
                }
            }
            .frame(height: 30, alignment: .bottom)
            .animation(.snappy(duration: 0.2), value: selection)

            Spacer(minLength: 8)

            if isRunning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在同步…").font(.callout).foregroundStyle(Color.accentColor)
                }
            }

            ControlGroup {
                Button {
                    step(by: 1)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .help("上一次")
                .disabled(index.map { $0 >= runs.count - 1 } ?? true)
                Button {
                    step(by: -1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .help("下一次")
                .disabled(index.map { $0 <= 0 } ?? true)
            }
            .fixedSize()
        }
    }

    /// Position of the selection in `runs` (0 = newest).
    private var index: Int? { runs.firstIndex { $0.url == selection } }

    private func step(by offset: Int) {
        guard let index, runs.indices.contains(index + offset) else { return }
        selection = runs[index + offset].url
    }
}

// MARK: - Run detail

private struct ResultStyle {
    let color: Color
    let symbol: String
    let title: String

    init(_ result: SyncLog.Result) {
        switch result {
        case .success: (color, symbol, title) = (.green, "checkmark", String(localized: "同步成功"))
        case .warning: (color, symbol, title) = (.orange, "exclamationmark", String(localized: "完成，但有警告"))
        case .error: (color, symbol, title) = (.red, "xmark", String(localized: "同步出错"))
        }
    }
}

private struct RunDetail: View {
    let run: RunEntry
    /// nil while loading; `.some(nil)` when the run has no saved change list.
    let changes: ChangeList??
    let now: Date

    @State private var filter: ChangeFilter = .all
    @State private var search = ""

    private var record: RunRecord { run.record }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                banner
                    .padding(.bottom, 14)
                stats
                    .padding(.bottom, 18)
                if !record.errors.isEmpty {
                    IssueList(title: String(localized: "错误"), messages: record.errors, color: .red,
                              systemImage: "xmark.octagon.fill")
                        .padding(.bottom, 18)
                }
                if !record.warnings.isEmpty {
                    IssueList(title: String(localized: "警告"), messages: record.warnings, color: .orange,
                              systemImage: "exclamationmark.triangle.fill")
                        .padding(.bottom, 18)
                }
                Section {
                    changeRows
                } header: {
                    changesHeader
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
        }
    }

    private var banner: some View {
        let style = ResultStyle(record.result)
        return HStack(spacing: 14) {
            Image(systemName: style.symbol)
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(Circle().fill(style.color.gradient))
            VStack(alignment: .leading, spacing: 3) {
                Text(style.title)
                    .font(.title3.weight(.semibold))
                Text("\(DateText.describe(record.start, now: now)) · 用时 \(Self.duration(record.duration))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(record.summary)
                .font(.callout.weight(.medium))
                .foregroundStyle(style.color)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(style.color.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(style.color.opacity(0.22)))
    }

    private var stats: some View {
        HStack(spacing: 10) {
            StatTile(label: String(localized: "stat.added", defaultValue: "新增"), value: "\(record.count(.added, .folder))",
                     systemImage: "plus.circle.fill", tint: .green)
            StatTile(label: String(localized: "stat.updated", defaultValue: "更新"), value: "\(record.count(.updated, .renamed))",
                     systemImage: "arrow.triangle.2.circlepath.circle.fill", tint: .blue)
            StatTile(label: String(localized: "stat.removed", defaultValue: "删除"), value: "\(record.count(.trashed, .deleted))",
                     systemImage: "trash.circle.fill", tint: .red)
            StatTile(label: String(localized: "stat.transferred", defaultValue: "传输"),
                     value: ByteCountFormatter.string(fromByteCount: record.bytes, countStyle: .file),
                     systemImage: "arrow.down.circle.fill", tint: .purple)
        }
    }

    // MARK: Changes

    private var changesHeader: some View {
        HStack(spacing: 12) {
            Text("变动明细")
                .font(.headline)
            Spacer()
            Picker("显示", selection: $filter) {
                ForEach(ChangeFilter.allCases) { filter in
                    Text(filter.title(count: count(filter))).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            SearchField(text: $search)
                .frame(width: 170)
        }
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder private var changeRows: some View {
        switch changes {
        case nil:
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(30)
        case .some(nil):
            note(String(localized: "这次同步没有保存变动明细。"), systemImage: "doc.questionmark")
        case .some(.some(let list)):
            let shown = filtered(list.changes)
            if list.changes.isEmpty {
                note(String(localized: "这次同步没有变动，目标已经是最新的。"), systemImage: "checkmark.seal")
            } else if shown.isEmpty {
                note(String(localized: "没有符合条件的项目"), systemImage: "line.3.horizontal.decrease.circle")
            } else {
                ForEach(Array(shown.enumerated()), id: \.offset) { index, change in
                    ChangeRow(change: change, target: record.target)
                    if index < shown.count - 1 {
                        Divider().padding(.leading, 38)
                    }
                }
                if list.omitted > 0 && filter == .all && search.isEmpty {
                    note(String(localized: "还有 \(list.omitted) 项没有列出。"), systemImage: "ellipsis.circle")
                }
            }
        }
    }

    private func note(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
    }

    private func count(_ filter: ChangeFilter) -> Int {
        filter.kinds.reduce(0) { $0 + record.count($1) }
    }

    private func filtered(_ changes: [Change]) -> [Change] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return changes.filter {
            filter.kinds.contains($0.kind) && (query.isEmpty || $0.path.localizedStandardContains(query))
        }
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        Duration.seconds(max(1, seconds.rounded()))
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow))
    }
}

private enum ChangeFilter: CaseIterable, Identifiable {
    case all, added, updated, removed
    var id: Self { self }

    var kinds: [Change.Kind] {
        switch self {
        case .all: Change.Kind.allCases
        case .added: [.added, .folder]
        case .updated: [.updated, .renamed]
        case .removed: [.trashed, .deleted]
        }
    }

    func title(count: Int) -> String {
        switch self {
        case .all: String(localized: "全部 \(count)")
        case .added: String(localized: "新增 \(count)")
        case .updated: String(localized: "更新 \(count)")
        case .removed: String(localized: "删除 \(count)")
        }
    }
}

private struct StatTile: View {
    let label: String
    let value: String
    let systemImage: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(label).foregroundStyle(.secondary)
            } icon: {
                Image(systemName: systemImage).foregroundStyle(tint)
            }
            .font(.callout)
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.07)))
    }
}

/// Errors or warnings: the first line of each message is its headline, the rest (paths, system errors) its detail.
private struct IssueList: View {
    let title: String
    let messages: [String]
    let color: Color
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title).font(.headline)
                Text("\(messages.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(color))
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(messages.enumerated()), id: \.offset) { index, message in
                    let lines = message.split(separator: "\n", maxSplits: 1).map(String.init)
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: systemImage)
                            .foregroundStyle(color)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(lines.first ?? message)
                            if lines.count > 1 {
                                Text(lines[1])
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    if index < messages.count - 1 {
                        Divider().padding(.leading, 38)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(color.opacity(0.2)))
        }
    }
}

private struct ChangeRow: View {
    let change: Change
    /// The run's target folder, to reveal the item in Finder.
    let target: String?
    @State private var hovering = false

    private var name: String { (change.path as NSString).lastPathComponent }
    private var parent: String { (change.path as NSString).deletingLastPathComponent }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Group {
                    if change.kind == .renamed, let from = change.from {
                        Text("\(from) → \(name)")
                    } else {
                        Text(name)
                    }
                }
                .lineLimit(1)
                .truncationMode(.middle)
                if !parent.isEmpty {
                    Text(parent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 8)
            if let bytes = change.bytes {
                Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(tint.opacity(0.12)))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.05) : .clear))
        .onHover { hovering = $0 }
        .contextMenu {
            if let url = itemURL, FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            Button("拷贝路径") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(itemURL?.path(percentEncoded: false) ?? change.path, forType: .string)
            }
        }
    }

    private var itemURL: URL? {
        target.map { URL(filePath: $0).appending(path: change.path) }
    }

    private var symbol: String {
        switch change.kind {
        case .added: "plus.circle.fill"
        case .updated: "arrow.triangle.2.circlepath.circle.fill"
        case .folder: "folder.fill.badge.plus"
        case .renamed: "pencil.circle.fill"
        case .trashed: change.isFolder == true ? "folder.fill.badge.minus" : "trash.circle.fill"
        case .deleted: change.isFolder == true ? "folder.fill.badge.minus" : "minus.circle.fill"
        }
    }

    private var tint: Color {
        switch change.kind {
        case .added, .folder: .green
        case .updated: .blue
        case .renamed: .purple
        case .trashed, .deleted: .red
        }
    }

    private var label: String {
        switch change.kind {
        case .added: String(localized: "change.added", defaultValue: "新增")
        case .updated: String(localized: "change.updated", defaultValue: "更新")
        case .folder: String(localized: "change.folder", defaultValue: "新文件夹")
        case .renamed: String(localized: "change.renamed", defaultValue: "改名")
        case .trashed: String(localized: "change.trashed", defaultValue: "废纸篓")
        case .deleted: String(localized: "change.deleted", defaultValue: "删除")
        }
    }
}

private struct SearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索文件", text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.1)))
    }
}

/// A task's state at a glance: syncing, last result, or overdue. Shared by the menu bar panel and the history window.
struct TaskStatusIcon: View {
    let task: SyncTask
    let store: SyncStore

    var body: some View {
        if store.isRunning(task) {
            ProgressView().controlSize(.small)
        } else if let log = store.logs[task.id], !store.isStale(task) {
            switch log.result {
            case .success: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .error: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            }
        } else {
            Image(systemName: "clock.badge.exclamationmark.fill").foregroundStyle(.orange)
        }
    }
}
