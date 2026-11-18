#!/bin/zsh
# Renders the README screenshots (docs/images/*-en.png and *-zh.png) from demo tasks,
# so no real folder names end up in them.
#
#   scripts/make-screenshots.sh
set -euo pipefail

ROOT=${0:A:h:h}
OUT=$ROOT/docs/images
DEMO=$(mktemp -d -t syncdock-demo)
trap 'rm -rf "$DEMO"' EXIT

xcodebuild -project "$ROOT/SyncDock.xcodeproj" -scheme SyncDock -configuration Debug \
    -derivedDataPath "$ROOT/build.noindex/DerivedData" build -quiet
APP=$ROOT/build.noindex/DerivedData/Build/Products/Debug/SyncDock.app/Contents/MacOS/SyncDock

# Demo tasks and run records in $DEMO/<lang>, read through SYNCDOCK_HOME.
/usr/bin/python3 -I - "$DEMO" "$HOME" <<'PY'
import os, sys, json, datetime
demo, home = sys.argv[1], sys.argv[2]
now = datetime.datetime.now().astimezone()
tasks = {
    "en": ["Photos to Backup Drive", "Documents to OneDrive", "Projects to Backup Drive"],
    "zh": ["照片-备份硬盘", "文稿-OneDrive", "项目-备份硬盘"],
}
specs = [  # source, target folder, schedule, keep .git, last run, items, bytes
    (f"{home}/Pictures/Photos", "/Volumes/Backup", {"kind": "daily", "hour": 21, "minute": 0}, False,
     now.replace(hour=9, minute=0) if now.hour >= 9 else now - datetime.timedelta(hours=1), 1284, 3_210_000_000),
    (f"{home}/Documents/Work", f"{home}/Library/CloudStorage/OneDrive-Personal", {"kind": "daily", "hour": 1, "minute": 30},
     False, (now - datetime.timedelta(days=1)).replace(hour=1, minute=30), 0, 0),
    (f"{home}/Desktop/Projects", "/Volumes/Backup", {"kind": "weekly", "hour": 18, "minute": 0, "weekdays": [1, 4]}, True,
     (now - datetime.timedelta(days=2)).replace(hour=18, minute=0), 342, 86_400_000),
]

import random

# What the latest run of each task changed; earlier runs get made-up counts.
latest_changes = [
    [("added", f"2026/11/IMG_{4810 + n}.HEIC", 2_500_000) for n in range(12)],
    [],
    [("added", "SyncDock/HistoryView.swift", 31_200), ("updated", "SyncDock/SyncEngine.swift", 14_800),
     ("updated", "SyncDock/SyncStore.swift", 9_600), ("folder", "SyncDock/Resources", None),
     ("added", "SyncDock/Resources/Icon.png", 412_000), ("updated", "README.md", 12_400),
     ("updated", ".git/index", 18_900), ("added", ".git/objects/4f/1c9e2a7b", 2_100),
     ("added", ".git/objects/a3/77d0b5e1", 3_900), ("updated", ".git/refs/heads/main", 41),
     ("updated", "docs/images/panel-en.png", 98_000), ("updated", "scripts/make-screenshots.sh", 6_100)],
]
problems = {  # run index (0 = latest) -> (result, errors, warnings)
    "en": {4: ("warning", [], ["The destination folder didn't exist and was recreated: /Volumes/Backup/Projects"]),
           9: ("error", ["Could not copy: Archive/2025 recording.mov\nThe operation couldn’t be completed. (No space left on device)"], [])},
    "zh": {4: ("warning", [], ["目标文件夹不存在，已重新创建：/Volumes/Backup/Projects"]),
           9: ("error", ["复制失败：Archive/2025 recording.mov\nThe operation couldn’t be completed. (No space left on device)"], [])},
}

def write_runs(log_dir, tid, i, last, items, size, lang):
    rng = random.Random(i)
    for n in range(20):
        start = (last - datetime.timedelta(days=n * (3 if i == 2 else 1))).replace(microsecond=0)
        if n == 0:
            changes = [{"kind": k, "path": p, **({"bytes": b} if b else {})} for k, p, b in latest_changes[i]]
            count, total = (len(changes), sum(c.get("bytes", 0) for c in changes)) if changes else (items, size)
            counts = {}
            for c in changes: counts[c["kind"]] = counts.get(c["kind"], 0) + 1
            if not changes and items: counts = {"added": items}
        else:
            count = rng.choice([0, 0, 3, 8, 15, 42])
            total = count * rng.randint(20_000, 900_000)
            counts = {"added": count // 3, "updated": count - count // 3} if count else {}
            changes = [{"kind": "updated", "path": f"file-{k}.txt", "bytes": total // count} for k in range(count)]
        result, errors, warnings = problems[lang].get(n, ("success", [], [])) if i == 2 else ("success", [], [])
        base = os.path.join(log_dir, f"{tid} {start:%Y-%m-%d %H%M%S}.000")
        json.dump({"start": start.isoformat(), "end": (start + datetime.timedelta(seconds=rng.randint(2, 95))).isoformat(),
                   "result": result, "items": count, "bytes": total, "errors": errors, "warnings": warnings,
                   "counts": counts, "source": SPECS_SRC[i], "target": SPECS_DST[i], "mode": "update"},
                  open(base + ".json", "w"))
        json.dump({"changes": changes, "omitted": 0}, open(base + ".changes.json", "w"))

SPECS_SRC = [s[0] for s in specs]
SPECS_DST = [os.path.join(s[1], os.path.basename(s[0])) for s in specs]

for lang, names in tasks.items():
    task_dir, log_dir = (os.path.join(demo, lang, d) for d in ("Tasks", "Logs"))
    for d in (task_dir, log_dir): os.makedirs(d)
    for i, (name, (src, dst, sched, git, last, items, size)) in enumerate(zip(names, specs)):
        tid = f"task-demo{i}"
        sched = {"weekdays": [7], **sched}
        json.dump({"id": tid, "name": name, "sourcePath": src, "targetFolder": dst, "createSubfolder": True,
                   "mode": "update", "excludeHidden": True, "includeGit": git, "schedule": sched},
                  open(os.path.join(task_dir, tid + ".json"), "w"))
        write_runs(log_dir, tid, i, last, items, size, lang)
PY

mkdir -p "$OUT"
render() { # lang appleLanguage name view
    SYNCDOCK_HOME=$DEMO/$1 "$APP" --snapshot "$DEMO/$3-$1.png" ${4:+"$4"} -AppleLanguages "($2)"
}
for lang apple in en en zh zh-Hans; do
    render $lang $apple panel
    render $lang $apple editor task-demo2
    render $lang $apple setup setup
    render $lang $apple history history:task-demo2
done

# Rounded corners, a soft shadow and transparent padding, like a window on screen.
/usr/bin/swift - "$DEMO" "$OUT" <<'SWIFT'
import AppKit
let (src, dst) = (CommandLine.arguments[1], CommandLine.arguments[2])
for file in try! FileManager.default.contentsOfDirectory(atPath: src) where file.hasSuffix(".png") {
    let image = NSImage(contentsOfFile: "\(src)/\(file)")!
    let rep = image.representations[0]
    let (w, h, pad) = (CGFloat(rep.pixelsWide), CGFloat(rep.pixelsHigh), CGFloat(48))
    let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w + 2 * pad), pixelsHigh: Int(h + 2 * pad),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
    let frame = NSRect(x: pad, y: pad, width: w, height: h)
    let shape = NSBezierPath(roundedRect: frame, xRadius: 24, yRadius: 24)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.25)
    shadow.shadowOffset = NSSize(width: 0, height: -6)
    shadow.shadowBlurRadius = 28
    shadow.set()
    NSColor.windowBackgroundColor.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    shape.addClip()
    image.draw(in: frame)
    NSColor(white: 0, alpha: 0.12).setStroke()
    shape.lineWidth = 2
    shape.stroke()
    NSGraphicsContext.current = nil
    try! out.representation(using: .png, properties: [:])!.write(to: URL(filePath: "\(dst)/\(file)"))
}
SWIFT

ls -1 "$OUT"
