import Foundation

/// Moves tasks from SyncDock 1.x, which ran them with FreeFileSync, to SyncDock's own engine.
///
/// A 1.x task is a `local.freefilesync.*` launch agent whose last argument is a FreeFileSync batch file.
/// Only batch files SyncDock could have written are imported: one-way, one source and target, and no
/// filters beyond the ones SyncDock offers. Anything else (two-way sync, extra filters…) is left running
/// in FreeFileSync untouched. The batch files themselves are kept.
enum LegacyImport {
    static let labelPrefix = "local.freefilesync."

    /// Returns the names of the imported tasks.
    @discardableResult
    static func run() -> [String] {
        guard !Paths.isTestHome else { return [] }
        let fm = FileManager.default
        let agents = (try? fm.contentsOfDirectory(at: Paths.launchAgents, includingPropertiesForKeys: nil)) ?? []
        var imported: [String] = []
        for agentURL in agents where agentURL.lastPathComponent.hasPrefix(labelPrefix) && agentURL.pathExtension == "plist" {
            guard let plist = NSDictionary(contentsOf: agentURL) as? [String: Any],
                  let label = plist["Label"] as? String,
                  let batchPath = (plist["ProgramArguments"] as? [String])?.last, batchPath.hasSuffix(".ffs_batch"),
                  let task = task(batchURL: URL(filePath: batchPath), schedule: Schedule(plistValue: plist["StartCalendarInterval"]))
            else { continue }
            do {
                try TaskFiles.save(task)
            } catch {
                continue
            }
            LaunchAgent.uninstall(label: label)
            imported.append(task.name)
        }
        return imported
    }

    static func task(batchURL: URL, schedule: Schedule) -> SyncTask? {
        guard let doc = try? XMLDocument(contentsOf: batchURL) else { return nil }
        func strings(_ xpath: String) -> [String] { ((try? doc.nodes(forXPath: xpath)) ?? []).compactMap(\.stringValue) }

        // Direction: SyncDock only ever wrote these two.
        guard (try? doc.nodes(forXPath: "/FreeFileSync/Synchronize/Changes"))?.isEmpty ?? true,
              let diff = (try? doc.nodes(forXPath: "/FreeFileSync/Synchronize/Differences"))?.first as? XMLElement
        else { return nil }
        let directions = ["LeftOnly", "LeftNewer", "RightNewer", "RightOnly"].map { diff.attribute(forName: $0)?.stringValue }
        let mode: SyncMode
        switch directions {
        case ["right", "right", "none", "none"]: mode = .update
        case ["right", "right", "right", "right"]: mode = .mirror
        default: return nil
        }

        // Folders: one pair, or the main pair plus the `.git` pair SyncDock adds for the same folders.
        let lefts = strings("/FreeFileSync/FolderPairs/Pair/Left"), rights = strings("/FreeFileSync/FolderPairs/Pair/Right")
        guard let source = lefts.first, let target = rights.first, !source.isEmpty, !target.isEmpty,
              Set(lefts).count == 1, Set(rights).count == 1, lefts.count <= 2
        else { return nil }

        // Filters: only patterns SyncDock writes, and no size or date limits.
        let known: Set<String> = ["*", "*/.*", "*/.DS_Store", "*/._*", "*/.git/", "*/.git/fsmonitor--daemon.ipc"]
        let allItems = strings("//Filter/Include/Item") + strings("//Filter/Exclude/Item")
        let limits = ((try? doc.nodes(forXPath: "//Filter/SizeMin | //Filter/SizeMax | //Filter/TimeSpan")) ?? [])
            .compactMap { ($0 as? XMLElement)?.attributes?.first?.stringValue }
        guard allItems.allSatisfy(known.contains), limits.allSatisfy({ $0 == "None" }) else { return nil }
        let excludes = strings("//Filter/Exclude/Item")
        let includeGit = strings("/FreeFileSync/FolderPairs/Pair/Filter/Include/Item").contains("*/.git/")
        let excludeHidden = excludes.contains("*/.*")
        guard lefts.count == 1 || includeGit else { return nil }

        // A target named like the source folder was set up as "target/<source name>".
        let targetURL = URL(filePath: target)
        let nested = targetURL.lastPathComponent == URL(filePath: source).lastPathComponent
        return SyncTask(id: SyncTask.newID(), name: batchURL.deletingPathExtension().lastPathComponent,
                        sourcePath: source,
                        targetFolder: nested ? targetURL.deletingLastPathComponent().folderPath : target,
                        createSubfolder: nested, mode: mode, excludeHidden: excludeHidden,
                        includeGit: excludeHidden && includeGit, schedule: schedule)
    }
}
