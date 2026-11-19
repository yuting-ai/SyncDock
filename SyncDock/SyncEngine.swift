import Darwin
import Foundation
import Synchronization

/// One-way folder sync: makes `target` follow `source`, either adding and updating only (`.update`)
/// or also removing what's gone from the source (`.mirror`).
///
/// Files are compared by size and modification time. A file is written to a temporary name next to
/// its destination and then renamed over it, so an interrupted run never leaves a half-written file.
/// Excluded items (see `Filter`) are left alone on both sides, and symbolic links, sockets and other
/// special files are skipped.
final class SyncEngine {
    struct Options {
        var source: URL
        var target: URL
        var mode: SyncMode
        var excludeHidden: Bool
        var includeGit: Bool
        var excludes: [String] = []
        /// Delete for good instead of moving to the Trash (cloud folders have no Trash to move to).
        var deletePermanently: Bool
    }

    struct Outcome {
        var result: SyncLog.Result
        var items = 0
        var bytes: Int64 = 0
        var errors: [String] = []
        var warnings: [String] = []
        /// Every change made, in order.
        var changes: [Change] = []
    }

    /// Clocks of FAT/exFAT drives tick in 2-second steps, so closer times count as equal.
    static let timeTolerance: TimeInterval = 2
    /// Prefix of the temporary files written before they replace their destination.
    static let tempPrefix = ".syncdock-tmp-"

    private let options: Options
    private let rules: ExcludeRules
    private let cancelled: Cancellation
    private var outcome = Outcome(result: .success)
    private var caseInsensitive = true

    init(options: Options, cancelled: Cancellation = Cancellation()) {
        self.options = options
        self.rules = ExcludeRules(options.excludes)
        self.cancelled = cancelled
    }

    func run() -> Outcome {
        let fm = FileManager.default
        let source = options.source, target = options.target

        guard Self.kind(of: source) == .folder else {
            fail(String(localized: "源文件夹不存在或无法访问：\(source.folderPath)"))
            return finish()
        }
        if Self.kind(of: target) == nil {
            // Only the last folder may be recreated; a missing drive must not end up on the internal disk.
            guard Self.kind(of: target.deletingLastPathComponent()) == .folder else {
                fail(String(localized: "目标文件夹的上级不存在：\(target.folderPath)"))
                return finish()
            }
            do {
                try fm.createDirectory(at: target, withIntermediateDirectories: false)
                warn(String(localized: "目标文件夹不存在，已重新创建：\(target.folderPath)"))
            } catch {
                fail(String(localized: "无法创建目标文件夹：\(target.folderPath)"), error)
                return finish()
            }
        } else if Self.kind(of: target) != .folder {
            fail(String(localized: "目标不是文件夹：\(target.folderPath)"))
            return finish()
        }

        let caseSensitive = (try? target.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?
            .volumeSupportsCaseSensitiveNames ?? false
        caseInsensitive = !caseSensitive

        syncFolder(source: source, target: target, relative: "", insideGit: false)
        return finish()
    }

    // MARK: Walking

    private func syncFolder(source: URL, target: URL, relative: String, insideGit: Bool) {
        guard !cancelled.isSet else { return }
        // A folder that can't be listed is skipped as a whole: deleting "extra" target items based on
        // an incomplete listing could remove files that still exist in the source.
        guard let sourceItems = list(source, relative: relative, insideGit: insideGit, isTarget: false),
              let targetItems = list(target, relative: relative, insideGit: insideGit, isTarget: true)
        else { return }

        if relative.isEmpty, options.mode == .mirror, sourceItems.isEmpty, !targetItems.isEmpty {
            // An empty source is far more often an unmounted or emptied disk than an intended wipe.
            fail(String(localized: "源文件夹是空的，为了不清空目标，本次镜像已取消：\(source.folderPath)"))
            return
        }

        var remaining: [String: Entry] = [:]
        for item in targetItems { remaining[key(item.name)] = item }

        var matched: [(Entry, Entry?)] = []
        var seen = Set<String>()
        for item in sourceItems {
            let k = key(item.name)
            guard seen.insert(k).inserted else {
                fail(String(localized: "目标磁盘不区分大小写，同名文件只能保留一个，已跳过：\(join(relative, item.name))"))
                continue
            }
            matched.append((item, remaining.removeValue(forKey: k)))
        }

        // Deletions first, so a mirror frees space before copying.
        if options.mode == .mirror {
            for item in remaining.values.sorted(by: { $0.name < $1.name }) {
                guard !cancelled.isSet else { return }
                delete(target.appending(path: item.name), relative: join(relative, item.name), isFolder: item.kind == .folder)
            }
        }

        for (src, dst) in matched {
            guard !cancelled.isSet else { return }
            let rel = join(relative, src.name)
            let srcURL = source.appending(path: src.name)
            var dstURL = target.appending(path: src.name)
            let enteringGit = insideGit || (src.kind == .folder && src.name == ".git")

            guard var dst else {
                if src.kind == .folder {
                    if createFolder(dstURL, relative: rel) {
                        syncFolder(source: srcURL, target: dstURL, relative: rel, insideGit: enteringGit)
                    }
                } else {
                    copy(src, from: srcURL, to: dstURL, relative: rel, isNew: true)
                }
                continue
            }

            // Same item, different case: give it the source's spelling.
            if dst.name != src.name,
               dst.name.precomposedStringWithCanonicalMapping != src.name.precomposedStringWithCanonicalMapping {
                let old = target.appending(path: dst.name)
                if Darwin.rename(old.path(percentEncoded: false), dstURL.path(percentEncoded: false)) == 0 {
                    record(.renamed, rel, from: dst.name)
                    dst.name = src.name
                } else {
                    dstURL = old
                }
            }

            switch (src.kind, dst.kind) {
            case (.folder, .folder):
                syncFolder(source: srcURL, target: dstURL, relative: rel, insideGit: enteringGit)
            case (.file, .file):
                if needsCopy(src, over: dst) {
                    copy(src, from: srcURL, to: dstURL, relative: rel, isNew: false)
                }
            default:
                // A file where the source has a folder, or the other way round.
                guard options.mode == .mirror else {
                    warn(String(localized: "目标里同名的项目类型不同（文件和文件夹），更新模式不会替换它：\(rel)"))
                    continue
                }
                guard delete(dstURL, relative: rel, isFolder: dst.kind == .folder) else { continue }
                if src.kind == .folder {
                    if createFolder(dstURL, relative: rel) {
                        syncFolder(source: srcURL, target: dstURL, relative: rel, insideGit: enteringGit)
                    }
                } else {
                    copy(src, from: srcURL, to: dstURL, relative: rel, isNew: true)
                }
            }
        }
    }

    private func needsCopy(_ src: Entry, over dst: Entry) -> Bool {
        let diff = src.modified.timeIntervalSince(dst.modified)
        if diff > Self.timeTolerance { return true }
        if diff < -Self.timeTolerance {
            // The target copy is newer: an update leaves it alone, a mirror puts the source back.
            return options.mode == .mirror
        }
        return src.size != dst.size
    }

    // MARK: Listing

    struct Entry {
        enum Kind { case file, folder }
        var name: String
        var kind: Kind
        var size: Int64
        var modified: Date
    }

    private static let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
                                                 .fileSizeKey, .contentModificationDateKey]

    private func list(_ folder: URL, relative: String, insideGit: Bool, isTarget: Bool) -> [Entry]? {
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Self.keys)
        } catch {
            fail(String(localized: "无法读取文件夹：\(folder.folderPath)"), error)
            return nil
        }
        var entries: [Entry] = []
        for url in urls {
            let name = url.lastPathComponent
            if isTarget && name.hasPrefix(Self.tempPrefix) {
                // Left behind by an interrupted run.
                try? FileManager.default.removeItem(at: url)
                continue
            }
            guard let values = try? url.resourceValues(forKeys: Set(Self.keys)),
                  values.isSymbolicLink != true else { continue }
            let kind: Entry.Kind
            if values.isDirectory == true {
                kind = .folder
            } else if values.isRegularFile == true {
                kind = .file
            } else {
                continue  // sockets, pipes, devices
            }
            guard Filter.includes(name: name, isFolder: kind == .folder, insideGit: insideGit,
                                  excludeHidden: options.excludeHidden, includeGit: options.includeGit),
                  !rules.excludes(relativePath: join(relative, name), name: name)
            else { continue }
            entries.append(Entry(name: name, kind: kind, size: Int64(values.fileSize ?? 0),
                                 modified: values.contentModificationDate ?? .distantPast))
        }
        return entries.sorted { $0.name < $1.name }
    }

    private func key(_ name: String) -> String {
        let nfc = name.precomposedStringWithCanonicalMapping
        return caseInsensitive ? nfc.lowercased() : nfc
    }

    // MARK: Changes

    private func createFolder(_ url: URL, relative: String) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            record(.folder, relative)
            return true
        } catch {
            fail(String(localized: "无法新建文件夹：\(relative)"), error)
            return false
        }
    }

    private func copy(_ src: Entry, from srcURL: URL, to dstURL: URL, relative: String, isNew: Bool) {
        let temp = dstURL.deletingLastPathComponent().appending(path: Self.tempPrefix + UUID().uuidString)
        let tempPath = temp.path(percentEncoded: false)
        // Clones on the same APFS volume, copies otherwise; data, extended attributes, permissions and dates.
        let status = copyfile(srcURL.path(percentEncoded: false), tempPath, nil,
                              copyfile_flags_t(COPYFILE_ALL | COPYFILE_CLONE))
        guard status == 0 else {
            let code = errno
            unlink(tempPath)
            fail(String(localized: "复制失败：\(relative)"), POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO))
            return
        }
        // A locked source file would otherwise give a copy that can never be replaced.
        var info = stat()
        if lstat(tempPath, &info) == 0, info.st_flags & UInt32(UF_IMMUTABLE | UF_APPEND) != 0 {
            chflags(tempPath, info.st_flags & ~UInt32(UF_IMMUTABLE | UF_APPEND))
        }
        guard Darwin.rename(tempPath, dstURL.path(percentEncoded: false)) == 0 else {
            let code = errno
            unlink(tempPath)
            fail(String(localized: "无法写入：\(relative)"), POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO))
            return
        }
        outcome.bytes += src.size
        record(isNew ? .added : .updated, relative, bytes: src.size)
    }

    @discardableResult
    private func delete(_ url: URL, relative: String, isFolder: Bool) -> Bool {
        do {
            if options.deletePermanently {
                try FileManager.default.removeItem(at: url)
            } else {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            }
            record(options.deletePermanently ? .deleted : .trashed, relative, isFolder: isFolder)
            return true
        } catch {
            fail(String(localized: "无法删除：\(relative)"), error)
            return false
        }
    }

    // MARK: Results

    private func record(_ kind: Change.Kind, _ relative: String, from: String? = nil, isFolder: Bool = false,
                        bytes: Int64? = nil) {
        outcome.items += 1
        outcome.changes.append(Change(kind: kind, path: relative, from: from, isFolder: isFolder ? true : nil, bytes: bytes))
    }

    private func fail(_ message: String, _ error: Error? = nil) {
        let text = error.map { message + "\n" + Self.describe($0) } ?? message
        outcome.errors.append(text)
    }

    private func warn(_ message: String) {
        outcome.warnings.append(message)
    }

    private func finish() -> Outcome {
        if cancelled.isSet { fail(String(localized: "同步被中断，下次会从中断处继续。")) }
        outcome.result = !outcome.errors.isEmpty ? .error : !outcome.warnings.isEmpty ? .warning : .success
        return outcome
    }

    /// The underlying POSIX error is the most useful part ("Operation not permitted" = no permission).
    private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
            return "\(ns.localizedDescription) (\(String(cString: strerror(Int32(underlying.code)))))"
        }
        return ns.localizedDescription
    }

    private func join(_ relative: String, _ name: String) -> String {
        relative.isEmpty ? name : relative + "/" + name
    }

    private static func kind(of url: URL) -> Entry.Kind? {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isFolder) else {
            return nil
        }
        return isFolder.boolValue ? .folder : .file
    }
}

/// Which items take part in a sync. Excluded items are invisible on both sides, so a mirror never deletes them.
enum Filter {
    /// Finder and resource-fork clutter, never synced.
    static func isJunk(_ name: String) -> Bool {
        name == ".DS_Store" || name.hasPrefix("._")
    }

    static func includes(name: String, isFolder: Bool, insideGit: Bool, excludeHidden: Bool, includeGit: Bool) -> Bool {
        if isJunk(name) { return false }
        if insideGit { return true }
        guard excludeHidden, name.hasPrefix(".") else { return true }
        return includeGit && isFolder && name == ".git"
    }
}

/// Set from a signal handler when launchd asks the run to stop.
final class Cancellation: Sendable {
    private let flag = Atomic<Bool>(false)
    var isSet: Bool { flag.load(ordering: .relaxed) }
    func set() { flag.store(true, ordering: .relaxed) }
}

/// The user's exclusions. A rule containing "/" is a path inside the source ("Project/build"); any
/// other rule is a name, with * and ? wildcards, matched at every level ("node_modules", "*.log").
/// Letter case and Unicode normalization don't matter.
struct ExcludeRules {
    private var paths = Set<String>()
    private var patterns: [String] = []

    init(_ rules: [String]) {
        for rule in rules {
            switch Self.parse(rule) {
            case .path(let path): paths.insert(Self.normalize(path))
            case .name(let pattern): patterns.append(Self.normalize(pattern))
            case nil: break
            }
        }
    }

    enum Rule: Equatable {
        case path(String)
        case name(String)
    }

    static func parse(_ rule: String) -> Rule? {
        let trimmed = rule.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.contains("/") else { return .name(trimmed) }
        let path = trimmed.split(separator: "/").joined(separator: "/")
        return path.isEmpty ? nil : .path(path)
    }

    func excludes(relativePath: String, name: String) -> Bool {
        if !paths.isEmpty && paths.contains(Self.normalize(relativePath)) { return true }
        guard !patterns.isEmpty else { return false }
        let name = Self.normalize(name)
        return patterns.contains { fnmatch($0, name, 0) == 0 }
    }

    private static func normalize(_ s: String) -> String {
        s.precomposedStringWithCanonicalMapping.lowercased()
    }
}
