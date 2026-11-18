import SwiftUI

/// First-run checklist: SyncDock has Full Disk Access, optional login item.
struct SetupView: View {
    let store: SyncStore
    @Environment(\.dismissWindow) private var dismissWindow
    /// Set once the user has pressed "检查" without success, to explain what may be missing.
    @State private var checkedAndDenied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "externaldrive.badge.checkmark")
                    .font(.system(size: 34))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text("欢迎使用 SyncDock").font(.title2.bold())
                    Text("SyncDock 会按计划在后台同步文件夹。开始之前，先完成下面这一步。")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)

            Divider()

            VStack(alignment: .leading, spacing: 22) {
                permissionStep
                loginStep
            }
            .padding(20)

            Divider()

            HStack {
                Spacer()
                Button("稍后再说") { dismissWindow(id: SyncDockApp.setupID) }
                    .keyboardShortcut(.cancelAction)
                Button("开始使用") { dismissWindow(id: SyncDockApp.setupID) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!store.setupComplete)
            }
            .padding(16)
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .navigationTitle("设置 SyncDock")
        // Coming back from System Settings: check again without making the user click.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.checkSetup()
        }
        .task { store.checkSetup() }
    }

    private var permissionStep: some View {
        Step(number: 1, title: "允许 SyncDock 访问所有文件", state: permissionState) {
            if store.hasFullDiskAccess {
                Text("已确认 SyncDock 拥有「完全磁盘访问权限」。").foregroundStyle(.secondary)
            } else {
                Text("定时同步在后台运行，没人能点「允许」，所以要提前授权，SyncDock 才能读取桌面、文稿和移动硬盘。")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text("1. 点「打开系统设置」")
                    Text("2. 点列表下方的 ＋，在「应用程序」里选择 SyncDock")
                    Text("3. 打开 SyncDock 旁边的开关，然后回到这里")
                }
                .font(.callout)
                if checkedAndDenied {
                    Label("还没有权限。如果开关已经打开，请退出 SyncDock 再重新打开。",
                          systemImage: "xmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                HStack {
                    Button("打开系统设置") { NSWorkspace.shared.open(FullDiskAccess.settingsURL) }
                    Button("检查") {
                        store.checkSetup()
                        checkedAndDenied = !store.hasFullDiskAccess
                    }
                }
            }
        }
    }

    private var permissionState: Step.State {
        store.hasFullDiskAccess ? .done : checkedAndDenied ? .failed : .todo
    }

    private var loginStep: some View {
        Step(number: 2, title: "登录时自动启动 SyncDock（推荐）", state: store.launchAtLogin ? .done : .optional) {
            Toggle("开机登录后在菜单栏显示同步状态", isOn: Binding(get: { store.launchAtLogin },
                                                      set: { store.setLaunchAtLogin($0) }))
                .toggleStyle(.checkbox)
        }
    }
}

private struct Step: View {
    enum State { case todo, done, failed, optional }

    let number: Int
    let title: LocalizedStringKey
    let state: State
    let content: AnyView

    init(number: Int, title: LocalizedStringKey, state: State, @ViewBuilder content: () -> some View) {
        self.number = number
        self.title = title
        self.state = state
        self.content = AnyView(content())
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            badge.frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                content
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var badge: some View {
        switch state {
        case .done:
            Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.red)
        case .todo, .optional:
            Text("\(number)")
                .font(.callout.bold())
                .frame(width: 22, height: 22)
                .background(Circle().strokeBorder(state == .todo ? Color.accentColor : .secondary, lineWidth: 1.5))
                .foregroundStyle(state == .todo ? Color.accentColor : .secondary)
        }
    }
}
