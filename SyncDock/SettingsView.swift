import SwiftUI

/// SyncDock ▸ Settings… (⌘,).
struct SettingsView: View {
    let store: SyncStore

    var body: some View {
        Form {
            Section {
                Toggle("登录时启动 SyncDock", isOn: Binding(get: { store.launchAtLogin },
                                                        set: { store.setLaunchAtLogin($0) }))
            } footer: {
                Text("登录后在菜单栏显示同步状态。定时同步由系统按时启动，即使 SyncDock 没有打开也会照常运行。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("权限") {
                LabeledContent("完全磁盘访问权限") {
                    if store.hasFullDiskAccess {
                        Label("已开启", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("打开系统设置") { NSWorkspace.shared.open(FullDiskAccess.settingsURL) }
                    }
                }
            }

            Section("数据") {
                LabeledContent("任务和同步记录") {
                    Button("在 Finder 中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([Paths.support])
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize()
        .onAppear { store.checkSetup() }
    }
}
