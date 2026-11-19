import SwiftUI

/// The new/edit task sheet of the main window.
struct EditorView: View {
    @Bindable var store: SyncStore
    /// A fixed height instead of fitting the window, for layout snapshots of the whole form.
    var fixedHeight: CGFloat? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var saveError: String?
    @State private var confirmingDelete = false

    private var draft: TaskDraft { store.draft }
    private var existingTask: SyncTask? { store.tasks.first { $0.id == draft.id } }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("名称", text: $store.draft.name, prompt: Text("例如：论文-移动硬盘"))
                    FolderField(title: String(localized: "源文件夹"), path: $store.draft.source, canCreate: false) { picked in
                        if store.draft.name.isEmpty { store.draft.name = picked.lastPathComponent }
                    }
                    FolderField(title: String(localized: "目标文件夹"), path: $store.draft.target, canCreate: true)
                    if !draft.source.isEmpty {
                        Toggle("在目标里新建「\(draft.sourceFolderName)」文件夹", isOn: $store.draft.createSubfolder)
                    }
                    destinationPreview
                }

                Section("同步方式") {
                    Picker("同步方式", selection: $store.draft.mode) {
                        Text("更新").tag(SyncMode.update)
                        Text("镜像").tag(SyncMode.mirror)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    modeExplanation
                }

                Section("过滤") {
                    Toggle("排除隐藏文件（以 . 开头的文件和文件夹）", isOn: $store.draft.excludeHidden)
                    Toggle("但保留 .git 文件夹（Git 仓库的历史记录）", isOn: $store.draft.includeGit)
                        .disabled(!draft.excludeHidden)
                        .padding(.leading, 18)
                }

                Section {
                    ExcludeList(rules: $store.draft.excludes, source: draft.source)
                } header: {
                    Text("排除")
                } footer: {
                    Text("可以选择源文件夹里的文件夹或文件，也可以填名称（支持 * 和 ? 通配符），名称在每一层都会排除。被排除的项目不会同步，目标里已有的也不会被删除。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("什么时候同步") {
                    Picker("运行方式", selection: $store.draft.schedule.kind) {
                        Text("仅手动").tag(Schedule.Kind.manual)
                        Text("每天").tag(Schedule.Kind.daily)
                        Text("每周").tag(Schedule.Kind.weekly)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    switch draft.schedule.kind {
                    case .manual:
                        Text("只在你点「立即同步」时同步。")
                            .font(.callout).foregroundStyle(.secondary)
                    case .daily:
                        timePicker
                    case .weekly:
                        WeekdayPicker(days: $store.draft.schedule.weekdays)
                        timePicker
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            footer.padding(16)
        }
        .frame(width: 540)
        .frame(minHeight: fixedHeight ?? 460, idealHeight: fixedHeight ?? 700, maxHeight: fixedHeight ?? 820)
        .navigationTitle(draft.isNew ? String(localized: "新建同步任务")
                                     : String(localized: "编辑：\(existingTask?.name ?? draft.name)"))
        .confirmationDialog("删除任务「\(draft.name)」？", isPresented: $confirmingDelete) {
            Button("删除任务", role: .destructive) {
                if let existingTask { store.delete(existingTask) }
                dismiss()
            }
        } message: {
            Text("只删除这个同步任务和它的定时设置（会移到废纸篓），已经同步过去的文件不受影响。")
        }
    }

    /// Spells out where files will land, and warns before mixing them into a folder that has other content.
    @ViewBuilder private var destinationPreview: some View {
        if !draft.source.isEmpty && !draft.target.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Label("同步到：\(TaskLoader.shorten(draft.effectiveTarget))", systemImage: "arrow.turn.down.right")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if !draft.createSubfolder && Self.hasVisibleContent(draft.target) {
                    Label("目标文件夹里已经有其他内容，「\(draft.sourceFolderName)」里的文件会直接和它们放在一起。",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private static func hasVisibleContent(_ path: String) -> Bool {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        return items.contains { !$0.hasPrefix(".") }
    }

    @ViewBuilder private var modeExplanation: some View {
        switch draft.mode {
        case .update:
            Text("把新增和修改过的文件复制到目标，不删除目标里的任何文件。")
                .font(.callout).foregroundStyle(.secondary)
        case .mirror:
            Label("让目标和源完全一致：源里删掉的文件，目标里也会删掉（移到废纸篓或云端回收站）。",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.callout).foregroundStyle(.orange)
        }
    }

    private var timePicker: some View {
        DatePicker("时间", selection: Binding(
            get: { Calendar.current.date(from: DateComponents(hour: draft.schedule.hour,
                                                               minute: draft.schedule.minute)) ?? .now },
            set: {
                let c = Calendar.current.dateComponents([.hour, .minute], from: $0)
                store.draft.schedule.hour = c.hour ?? 0
                store.draft.schedule.minute = c.minute ?? 0
            }), displayedComponents: .hourAndMinute)
    }

    private var footer: some View {
        HStack {
            if !draft.isNew {
                Button("删除…", role: .destructive) { confirmingDelete = true }
            }
            Spacer()
            if let message = saveError ?? store.validationError() {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(saveError == nil ? Color.secondary : .red)
                    .lineLimit(2)
            }
            Button("取消") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("保存并同步") { save(runAfter: true) }
                .disabled(store.validationError() != nil || draft.requiresVolumeMissing)
            Button("保存") { save(runAfter: false) }
                .keyboardShortcut(.defaultAction)
                .disabled(store.validationError() != nil)
        }
    }

    private func save(runAfter: Bool) {
        do {
            let task = try store.saveDraft()
            saveError = nil
            if runAfter { store.runNow(id: task.id) }
            dismiss()
        } catch {
            saveError = String(localized: "保存失败：\(error.localizedDescription)")
        }
    }
}

private extension TaskDraft {
    var requiresVolumeMissing: Bool {
        guard let volume = SyncTask.requiredVolume(source: source, target: effectiveTarget) else { return false }
        return !FileManager.default.fileExists(atPath: volume)
    }
}

private struct FolderField: View {
    let title: String
    @Binding var path: String
    let canCreate: Bool
    var onPick: (URL) -> Void = { _ in }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                if path.isEmpty {
                    Text("未选择").foregroundStyle(.tertiary)
                } else {
                    Label(TaskLoader.shorten(path), systemImage: "folder")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(path)
                }
                Button("选择…", action: choose)
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = canCreate
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "选择")
        panel.message = String(localized: "选择\(title)")
        if !path.isEmpty { panel.directoryURL = URL(filePath: path) }
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        path = url.folderPath
        onPick(url)
    }
}

/// Monday-first day toggles; values use launchd numbering (1 = Monday … 7 = Sunday).
private struct WeekdayPicker: View {
    @Binding var days: Set<Int>
    /// Monday first, in the user's language (symbols start at Sunday).
    private let names = Array(Calendar.current.shortStandaloneWeekdaySymbols.dropFirst())
        + [Calendar.current.shortStandaloneWeekdaySymbols[0]]

    var body: some View {
        LabeledContent("星期") {
            HStack(spacing: 4) {
                ForEach(1...7, id: \.self) { day in
                    Toggle(names[day - 1], isOn: Binding(
                        get: { days.contains(day) },
                        set: { if $0 { days.insert(day) } else { days.remove(day) } }))
                        .toggleStyle(.button)
                }
            }
        }
    }
}


/// The task's exclusions: items picked inside the source (stored as "/relative/path") and name patterns.
private struct ExcludeList: View {
    @Binding var rules: [String]
    let source: String
    @State private var newName = ""
    @State private var pickError: String?

    var body: some View {
        if rules.isEmpty {
            Text("没有排除任何项目。")
                .foregroundStyle(.secondary)
        }
        ForEach(rules, id: \.self) { rule in
            HStack(spacing: 8) {
                let isPath = ExcludeRules.parse(rule).map { if case .path = $0 { true } else { false } } ?? false
                Image(systemName: isPath ? "folder" : "tag")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(isPath ? String(rule.drop { $0 == "/" }) : rule)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(isPath ? String(localized: "源文件夹里的这一项") : String(localized: "名为这个的项目，在每一层都会排除"))
                Spacer()
                Button {
                    rules.removeAll { $0 == rule }
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("移除")
            }
        }
        HStack(spacing: 8) {
            TextField("名称", text: $newName, prompt: Text("名称，例如 node_modules 或 *.log"))
                .labelsHidden()
                .onSubmit(addName)
            Button("添加", action: addName)
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("选择…", action: choose)
                .disabled(source.isEmpty)
                .help("选择源文件夹里要排除的文件夹或文件")
        }
        if let pickError {
            Text(pickError)
                .font(.callout)
                .foregroundStyle(.red)
        }
    }

    private func addName() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if !rules.contains(name) { rules.append(name) }
        newName = ""
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "排除")
        panel.message = String(localized: "选择源文件夹里不需要同步的文件夹或文件")
        panel.directoryURL = URL(filePath: source)
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        let root = URL(filePath: source).standardizedFileURL.folderPath + "/"
        var outside = false
        for url in panel.urls {
            let path = url.standardizedFileURL.folderPath
            guard path.hasPrefix(root) else { outside = true; continue }
            let rule = "/" + path.dropFirst(root.count)
            if !rules.contains(rule) { rules.append(rule) }
        }
        pickError = outside ? String(localized: "只能排除源文件夹里面的项目。") : nil
    }
}
