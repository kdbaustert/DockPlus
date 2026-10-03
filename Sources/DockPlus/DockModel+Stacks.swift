import AppKit
import SwiftUI

/// How a stack orders what it shows — Finder's names, and the first of them is the old behaviour.
enum StackSort: String, CaseIterable, StackOption {
    case dateAdded, dateModified, name, kind

    static let standard = StackSort.dateAdded

    var title: String {
        switch self {
        case .dateAdded: "Date Added"
        case .dateModified: "Date Modified"
        case .name: "Name"
        case .kind: "Kind"
        }
    }
}

/// How a click on a stack in the dock shows it: the menu it always opened, or a grid of large icons
/// over the icon.
enum StackDisplay: String, CaseIterable, StackOption {
    case menu, grid

    static let standard = StackDisplay.menu

    var title: String {
        switch self {
        case .menu: "Menu"
        case .grid: "Grid"
        }
    }
}

/// One thing inside a stack's folder, with what the sorts need already read off disk.
struct StackEntry: Equatable {
    let url: URL
    let name: String
    let added: Date?
    let modified: Date?
    /// Finder's kind ("PDF document", "Folder"), which is what sorting by kind groups on.
    let kind: String
    /// A folder that opens as a submenu. Packages are directories too, but an app or an .rtfd is a
    /// file to open, not a place to browse.
    let isFolder: Bool
}

extension DockModel {
    /// How many items each level of a stack lists. More makes a menu taller than the screen.
    nonisolated static let stackLimit = 20
    /// A grid fits more in the same height: six columns by five rows of roughly 100pt cells, plus the
    /// title and footer, comes to about 600pt — inside the visible height above the dock on a 1280 by
    /// 800 display, the smallest a current Mac offers. Calculated from the cell size, not measured.
    nonisolated static let stackGridLimit = 30

    /// A folder stack: a menu at the pointer, with subfolders as submenus read only as they open.
    func showStack(_ folder: URL) {
        let menu = StackMenu(folder: folder, sort: settings.stackSort(for: folder.path))
        // The top level opens now, so it is read now; `popUp` would ask its delegate anyway, and
        // `load` runs once however often it is asked.
        menu.load()
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    /// A Grid stack clicked on the bar. The click comes through here, not `open`.
    func openAsGrid(_ item: DockItem) -> Bool {
        guard item.kind == .folder, let url = item.url, settings.stackDisplay(for: url.path) == .grid else {
            return false
        }
        return showStackGrid?(item) ?? false
    }

    /// The first `limit` entries in `sort`'s order: the dates newest first, name and kind as Finder
    /// orders them. Ties fall back to the name, so a folder of items sharing one date — or with no
    /// date at all — lists the same way every time. Pure, for the tests.
    nonisolated static func stackContents(
        _ entries: [StackEntry], sortedBy sort: StackSort, limit: Int = stackLimit
    ) -> [StackEntry] {
        func byName(_ a: StackEntry, _ b: StackEntry) -> Bool {
            a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        func newer(_ a: Date, _ b: Date, _ x: StackEntry, _ y: StackEntry) -> Bool {
            a != b ? a > b : byName(x, y)
        }
        let sorted = entries.sorted { a, b in
            switch sort {
            case .dateAdded:
                // An item with no added date — some volumes do not record one — falls back to its
                // modification date, as the stack always did.
                newer(a.added ?? a.modified ?? .distantPast, b.added ?? b.modified ?? .distantPast, a, b)
            case .dateModified:
                newer(a.modified ?? .distantPast, b.modified ?? .distantPast, a, b)
            case .name:
                byName(a, b)
            case .kind:
                switch a.kind.localizedStandardCompare(b.kind) {
                case .orderedSame: byName(a, b)
                case let order: order == .orderedAscending
                }
            }
        }
        return Array(sorted.prefix(limit))
    }
}

/// One level of a stack. Its own delegate, so each subfolder is listed only when its submenu is
/// about to open — a stack of a hundred folders reads one directory per level actually opened, not
/// the tree — and only once per click, however often the pointer passes back over it.
final class StackMenu: NSMenu, NSMenuDelegate {
    private let folder: URL
    private let sort: StackSort
    private var isLoaded = false

    init(folder: URL, sort: StackSort) {
        self.folder = folder
        self.sort = sort
        super.init(title: folder.lastPathComponent)
        delegate = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func menuNeedsUpdate(_ menu: NSMenu) { load() }

    /// Nothing in a stack has a key equivalent. Without this answer AppKit populates a delegate's
    /// menu — through `menuNeedsUpdate` — to search it for one, which would read every subfolder
    /// a keystroke reached rather than only the ones opened.
    func menuHasKeyEquivalent(
        _ menu: NSMenu, for event: NSEvent, target: AutoreleasingUnsafeMutablePointer<AnyObject?>,
        action: UnsafeMutablePointer<Selector?>
    ) -> Bool {
        false
    }

    func load() {
        guard !isLoaded else { return }
        isLoaded = true
        let (entries, isDenied) = Self.read(folder, needsKind: sort == .kind)
        let shown = DockModel.stackContents(entries, sortedBy: sort)
        for entry in shown {
            let icon = NSWorkspace.shared.icon(forFile: entry.url.path)
            icon.size = NSSize(width: 16, height: 16)
            if entry.isFolder {
                // No action: choosing a folder opens its submenu. The folder itself opens from the
                // "Open in Finder" at the foot of that submenu.
                let item = NSMenuItem(title: entry.name, action: nil, keyEquivalent: "")
                item.image = icon
                item.submenu = StackMenu(folder: entry.url, sort: sort)
                addItem(item)
            } else {
                addItem(ClosureMenuItem(entry.name, image: icon) { NSWorkspace.shared.open(entry.url) })
            }
        }
        if isDenied {
            let denied = NSMenuItem(title: "DockPlus can't read this folder", action: nil, keyEquivalent: "")
            denied.isEnabled = false
            addItem(denied)
            addItem(ClosureMenuItem("Open Files and Folders Settings…", handler: Self.openPrivacySettings))
        } else if shown.isEmpty {
            let empty = NSMenuItem(title: "No Items", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            addItem(empty)
        }
        addItem(.separator())
        let folder = folder
        addItem(ClosureMenuItem("Open in Finder") { NSWorkspace.shared.open(folder) })
    }

    /// `folder`'s contents, unsorted, or none and `isDenied`. Desktop, Documents, Downloads and
    /// removable volumes are behind a privacy permission; a folder DockPlus may not read is not an
    /// empty one. Any other failure reads as empty. `needsKind` is off for a sort that never reads
    /// the kind: it is a Launch Services lookup per file, and the one cost worth skipping.
    static func read(_ folder: URL, needsKind: Bool = true) -> (entries: [StackEntry], isDenied: Bool) {
        do {
            return (try entries(in: folder, needsKind: needsKind), false)
        } catch {
            return ([], (error as? CocoaError)?.code == .fileReadNoPermission)
        }
    }

    static func openPrivacySettings() {
        NSWorkspace.shared.openPrivacyPane("FilesAndFolders")
    }

    private static func entries(in folder: URL, needsKind: Bool) throws -> [StackEntry] {
        var keys: [URLResourceKey] = [
            .addedToDirectoryDateKey, .contentModificationDateKey, .isDirectoryKey, .isPackageKey,
        ]
        if needsKind { keys.append(.localizedTypeDescriptionKey) }
        let urls = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        )
        return urls.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return StackEntry(
                url: url, name: url.lastPathComponent, added: values?.addedToDirectoryDate,
                modified: values?.contentModificationDate, kind: values?.localizedTypeDescription ?? "",
                isFolder: values?.isDirectory == true && values?.isPackage != true
            )
        }
    }
}

/// A choice each stack makes for itself — its sort, how it displays — kept in a map from the stack's
/// path to the choice's raw value, beside `stacks`. One protocol so every such map is stored and
/// pruned by the same rule.
protocol StackOption: RawRepresentable<String>, Equatable {
    /// What a stack never set uses: what every stack did before the choice existed.
    static var standard: Self { get }
}

extension StackOption {
    /// The stack at `path`'s choice in the stored map. One never set is the standard one; so is a
    /// value this DockPlus does not know, from a newer one or a hand-edited file. Pure, for the tests.
    static func of(_ path: String, in stored: [String: String]) -> Self {
        stored[path].flatMap(Self.init(rawValue:)) ?? standard
    }

    /// The stored map with `path` set to `option`. Only what differs from the standard is kept, and
    /// entries for stacks no longer in the dock go on the way: removing a stack does not come through
    /// here, so this is where its leftover is dropped. Pure, for the tests.
    static func storing(
        _ option: Self, for path: String, in stored: [String: String], stacks: [String]
    ) -> [String: String] {
        var kept = stored.filter { stacks.contains($0.key) }
        kept[path] = option == standard ? nil : option.rawValue
        return kept
    }
}

extension DockSettings {
    func stackSort(for path: String) -> StackSort {
        .of(path, in: stackSorts)
    }

    func setStackSort(_ sort: StackSort, for path: String) {
        let sorts = StackSort.storing(sort, for: path, in: stackSorts, stacks: stacks)
        if sorts != stackSorts { stackSorts = sorts }
    }

    func stackDisplay(for path: String) -> StackDisplay {
        .of(path, in: stackDisplays)
    }

    func setStackDisplay(_ display: StackDisplay, for path: String) {
        let displays = StackDisplay.storing(display, for: path, in: stackDisplays, stacks: stacks)
        if displays != stackDisplays { stackDisplays = displays }
    }
}

/// Sort By in a stack's right-click menu, as the macOS Dock has it. Toggles rather than a Picker for
/// the reason `AssignToMenu` gives: in a SwiftUI menu, a Toggle is what draws the checkmark.
struct StackSortMenu: View {
    let path: String
    let settings: DockSettings

    var body: some View {
        let current = settings.stackSort(for: path)
        Menu("Sort By") {
            ForEach(StackSort.allCases, id: \.self) { sort in
                Toggle(sort.title, isOn: Binding(
                    get: { current == sort },
                    set: { on in
                        if on { settings.setStackSort(sort, for: path) }
                    }
                ))
            }
        }
    }
}

/// View Content As, beside Sort By — the macOS Dock's wording for its own Fan/Grid/List choice.
/// Toggles for the checkmark, as `StackSortMenu`.
struct StackDisplayMenu: View {
    let path: String
    let settings: DockSettings

    var body: some View {
        let current = settings.stackDisplay(for: path)
        Menu("View Content As") {
            ForEach(StackDisplay.allCases, id: \.self) { display in
                Toggle(display.title, isOn: Binding(
                    get: { current == display },
                    set: { on in
                        if on { settings.setStackDisplay(display, for: path) }
                    }
                ))
            }
        }
    }
}
