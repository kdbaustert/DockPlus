import XCTest
@testable import DockPlus

final class StackSortTests: XCTestCase {
    private func entry(
        _ name: String, added: TimeInterval? = nil, modified: TimeInterval? = nil, kind: String = "Document",
        isFolder: Bool = false
    ) -> StackEntry {
        StackEntry(
            url: URL(fileURLWithPath: "/stack/" + name), name: name,
            added: added.map(Date.init(timeIntervalSince1970:)),
            modified: modified.map(Date.init(timeIntervalSince1970:)), kind: kind, isFolder: isFolder)
    }

    private func names(_ entries: [StackEntry], _ sort: StackSort, limit: Int = DockModel.stackLimit) -> [String] {
        DockModel.stackContents(entries, sortedBy: sort, limit: limit).map(\.name)
    }

    func testDateAddedIsNewestFirst() {
        let entries = [entry("old", added: 1), entry("new", added: 3), entry("mid", added: 2)]
        XCTAssertEqual(names(entries, .dateAdded), ["new", "mid", "old"])
    }

    /// The stack's behaviour before sorts existed: no added date falls back to the modification date.
    func testDateAddedFallsBackToModified() {
        let entries = [entry("added", added: 2), entry("modifiedOnly", modified: 3), entry("neither")]
        XCTAssertEqual(names(entries, .dateAdded), ["modifiedOnly", "added", "neither"])
    }

    func testDateModifiedIgnoresAdded() {
        let entries = [entry("a", added: 9, modified: 1), entry("b", added: 1, modified: 5)]
        XCTAssertEqual(names(entries, .dateModified), ["b", "a"])
    }

    /// Finder's order: numbers by value and case folded, so "File 10" follows "file 2".
    func testNameIsFinderOrder() {
        let entries = [entry("File 10"), entry("file 2"), entry("Apple")]
        XCTAssertEqual(names(entries, .name), ["Apple", "file 2", "File 10"])
    }

    func testKindGroupsThenNames() {
        let entries = [
            entry("z.pdf", kind: "PDF document"), entry("Photos", kind: "Folder", isFolder: true),
            entry("a.pdf", kind: "PDF document"), entry("Music", kind: "Folder", isFolder: true),
        ]
        XCTAssertEqual(names(entries, .kind), ["Music", "Photos", "a.pdf", "z.pdf"])
    }

    /// Equal dates would otherwise list in whatever order the directory came back in.
    func testTiesFallBackToName() {
        let entries = [entry("b", added: 1), entry("c", added: 1), entry("a", added: 1)]
        XCTAssertEqual(names(entries, .dateAdded), ["a", "b", "c"])
        XCTAssertEqual(names(entries.map { entry($0.name) }, .dateModified), ["a", "b", "c"])
    }

    /// The cap is taken after the sort: the first 20 by the chosen order, not 20 of anything sorted.
    func testCapKeepsTheFirstBySort() {
        let entries = (0..<30).map { entry("item \($0)", added: TimeInterval($0)) }
        let newest = names(entries, .dateAdded)
        XCTAssertEqual(newest.count, 20)
        XCTAssertEqual(newest.first, "item 29")
        XCTAssertEqual(newest.last, "item 10")
        XCTAssertEqual(names(entries, .name, limit: 3), ["item 0", "item 1", "item 2"])
    }

    func testEmptyFolderListsNothing() {
        XCTAssertEqual(names([], .kind), [])
    }

    // MARK: - Stored per stack

    func testSortIsPerStackAndDefaultsToDateAdded() {
        let stacks = ["/a", "/b"]
        let sorts = StackSort.storing(.kind, for: "/a", in: [:], stacks: stacks)
        XCTAssertEqual(StackSort.of("/a", in: sorts), .kind)
        XCTAssertEqual(StackSort.of("/b", in: sorts), .dateAdded)
    }

    /// The default is not stored, so an untouched stack adds nothing to the settings file.
    func testDateAddedIsNotStored() {
        let sorts = StackSort.storing(.dateAdded, for: "/a", in: ["/a": "name"], stacks: ["/a"])
        XCTAssertEqual(sorts, [:])
    }

    /// A removed stack's leftover goes on the next write.
    func testStoringDropsRemovedStacks() {
        let sorts = StackSort.storing(.name, for: "/a", in: ["/gone": "kind", "/b": "kind"], stacks: ["/a", "/b"])
        XCTAssertEqual(sorts, ["/a": "name", "/b": "kind"])
    }

    /// A value a newer DockPlus wrote, or a hand-edited file, reads as the default rather than failing.
    func testUnknownSortReadsAsDateAdded() {
        XCTAssertEqual(StackSort.of("/a", in: ["/a": "size"]), .dateAdded)
    }

    /// An older settings file has no sorts at all; one written now carries them beside the plain list.
    func testSettingsFilesCarrySortsBesideStacks() throws {
        let old = try PortableSettings.decoded(from: Data(#"{"stacks": ["/a"]}"#.utf8))
        XCTAssertEqual(old.stacks, ["/a"])
        XCTAssertNil(old.stackSorts)
        let current = PortableSettings(stacks: ["/a"], stackSorts: ["/a": "kind"])
        XCTAssertEqual(try PortableSettings.decoded(from: current.encoded()), current)
    }

    /// The kind is a Launch Services lookup per file, read only for the sort that groups on it.
    func testKindIsReadOnlyWhenAskedFor() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("StackSortTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data().write(to: folder.appendingPathComponent("note.txt"))
        XCTAssertFalse(try XCTUnwrap(StackMenu.read(folder).entries.first).kind.isEmpty)
        XCTAssertEqual(try XCTUnwrap(StackMenu.read(folder, needsKind: false).entries.first).kind, "")
    }
}
