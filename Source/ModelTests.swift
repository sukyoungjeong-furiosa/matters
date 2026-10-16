import Foundation

@main struct ModelTests {
  @MainActor static func main() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "MattersModel-" + UUID().uuidString)
    let fm = FileManager.default
    for name in ["00-someday", "10-agendas", "20-queue", "30-progress", "90-done", "99-archive"] {
      try fm.createDirectory(
        at: root.appendingPathComponent(name), withIntermediateDirectories: true)
    }
    defer { try? fm.removeItem(at: root) }
    let model = Workspace(rootURL: root, startMonitoring: false)
    var count = 0
    func check(_ condition: @autoclosure () -> Bool, _ label: String) {
      precondition(condition(), label)
      count += 1
      print("PASS: " + label)
    }
    check(model.folders.count == 7, "Discovers actual folder structure, no fixed stages")
    model.renderedMode = true
    check(
      model.create(name: "new-matter.md", folder: "00-someday", body: "custom field: any value\n"),
      "Create and open a free-form document")
    check(model.renderedMode, "New documents open in rich edit mode")
    let beforeModeSwitch = try Data(contentsOf: model.selected!)
    model.renderedMode = true
    model.renderedMode = false
    let afterModeSwitch = try Data(contentsOf: model.selected!)
    check(
      beforeModeSwitch == afterModeSwitch && !model.dirty,
      "Editor mode switches do not modify Markdown files")
    let assets = MarkdownAssets()
    assets.root = FileStore.canonical(root)
    assets.directory = assets.root.appendingPathComponent("00-someday")
    let localAsset = assets.localURL(for: URL(string: "matters-asset://document/image%20file.png")!)
    check(localAsset?.lastPathComponent == "image file.png", "Relative image paths decode spaces")
    check(
      assets.localURL(for: URL(string: "matters-asset://document/../../../outside.png")!) == nil,
      "Local image paths cannot escape the workspace")
    check(
      assets.localURL(for: URL(string: "file:///etc/passwd")!) == nil,
      "Local asset handler rejects arbitrary local file URLs")
    check(
      model.selected?.lastPathComponent == "new-matter.md" && !model.dirty,
      "New document selected with clean baseline")
    check(model.visibleFiles.count == 1, "Created document shown in chosen folder")
    model.edited("priority: now\nFree-form body\n")
    check(model.dirty, "Editor marks actual changes")
    check(model.save(), "Explicit save succeeds")
    let saved = try String(contentsOf: model.selected!, encoding: .utf8)
    check(saved == model.text, "Editor saves exact text without adding fields")
    check(
      model.relocate(name: "moved-matter.txt", folder: "20-queue"), "Rename and move an actual file"
    )
    check(
      model.files.first?.folder == "20-queue"
        && model.selected?.lastPathComponent == "moved-matter.txt", "Selection follows moved file")
    model.edited("Edited just before moving\n")
    let oldURL = model.selected!
    check(
      model.moveDocument(oldURL, to: "30-progress"),
      "Quick state change saves pending edits and moves file")
    check(
      !fm.fileExists(atPath: oldURL.path)
        && model.selected?.deletingLastPathComponent().lastPathComponent == "30-progress",
      "Quick move updates selected path and removes old path")
    let movedText = try String(contentsOf: model.selected!, encoding: .utf8)
    check(
      movedText == "Edited just before moving\n" && !model.dirty,
      "Pending edits preserved byte-for-byte after move")
    check(model.scope == "folder:20-queue", "Quick moves preserve the current list for triage")
    let other = try FileStore.child(root: root, folder: "00-someday", name: "another-document.md")
    try FileStore.create(url: other, text: "Another document body")
    model.refresh()
    model.edited("Active document edits")
    let editingURL = model.selected
    check(
      model.moveDocument(other, to: "10-agendas"),
      "Context menu or drop can move an unselected document")
    check(
      model.selected == editingURL && model.text == "Active document edits" && model.dirty,
      "Moving an unselected file preserves the active editing buffer")
    check(model.save(), "Active editor can save after another file moves")
    let collision = try FileStore.child(
      root: root, folder: "90-done", name: model.selected!.lastPathComponent)
    try FileStore.create(url: collision, text: "Keep existing content")
    check(
      !model.moveDocument(model.selected!, to: "90-done"),
      "Quick move refuses destination name collision")
    let collisionText = try String(contentsOf: collision, encoding: .utf8)
    check(
      collisionText == "Keep existing content" && model.selected == editingURL,
      "Collision preserves both documents and selection")
    model.error = nil
    check(
      model.moveDocument(model.selected!, to: "30-progress"),
      "Moving to the current folder is harmless")
    check(
      !model.moveDocument(
        root.deletingLastPathComponent().appendingPathComponent("outside.md"), to: "20-queue"),
      "Drop cannot move an unknown external file")
    model.error = nil
    let list = DocumentList.Coordinator(model: model)
    list.documents = model.files.sorted { $0.relativePath < $1.relativePath }
    let row = list.documents.firstIndex { $0.url.path == editingURL?.path }!
    let otherRow = list.documents.firstIndex { $0.url.path != editingURL?.path }!
    list.open(row: otherRow)
    check(
      model.selected?.path == list.documents[otherRow].url.path,
      "Native row selection opens the clicked document")
    model.edited("Unsaved edits in the other document\n")
    let otherSelected = model.selected!
    list.open(row: row)
    let otherSaved = try String(contentsOf: otherSelected, encoding: .utf8)
    check(
      otherSaved == "Unsaved edits in the other document\n"
        && model.selected?.path == editingURL?.path,
      "Row switch saves the old buffer before opening the new document")
    list.open(row: -1)
    list.open(row: 999)
    check(
      model.selected?.path == editingURL?.path,
      "Transient empty or stale row selections do not clear the editor")
    let selected = model.selected!
    try "External editor changes".write(to: selected, atomically: true, encoding: .utf8)
    model.refresh()
    check(
      model.text == "External editor changes" && !model.dirty,
      "External edit reflected when editor is clean")
    model.edited("Preserve my pending edits")
    try "Concurrent external changes".write(to: selected, atomically: true, encoding: .utf8)
    model.refresh()
    check(
      model.conflict && model.text == "Preserve my pending edits",
      "Concurrent edits preserve editor buffer")
    list.open(row: otherRow)
    check(
      model.selected == selected && model.text == "Preserve my pending edits",
      "Native list selection cannot discard a conflicted document")
    check(!model.save(reportError: false), "Conflicting save refused")
    let retained = try String(contentsOf: selected, encoding: .utf8)
    check(retained == "Concurrent external changes", "External version preserved on disk")
    model.select(nil)
    check(
      model.selected == selected && model.text == "Preserve my pending edits",
      "Cannot navigate away and lose conflicted changes")
    check(
      !model.create(name: "another-matter.md", folder: "10-agendas", body: ""),
      "New document cannot discard a conflicting buffer")
    check(
      !model.moveDocument(selected, to: "99-archive"),
      "State change cannot bypass an external edit conflict")
    let richRoot = root.appendingPathComponent("rich-tests")
    try fm.createDirectory(at: richRoot, withIntermediateDirectories: true)
    let a = richRoot.appendingPathComponent("a.md")
    let b = richRoot.appendingPathComponent("b.md")
    try FileStore.create(url: a, text: "Original")
    try FileStore.create(url: b, text: "Second")
    let rich = Workspace(rootURL: richRoot, startMonitoring: false)
    rich.select(a)
    rich.renderedEdit(url: a, base: "Original", value: "Cell edits")
    check(rich.text == "Cell edits" && rich.dirty, "Rendered edits enter the same autosave buffer")
    rich.renderedEdit(url: a, base: "Original", value: "Stale message")
    check(rich.text == "Cell edits", "Stale rendered messages cannot overwrite newer edits")
    rich.select(b)
    rich.renderedEdit(url: a, base: "Cell edits", value: "Final input")
    let late = try String(contentsOf: a, encoding: .utf8)
    check(
      late == "Final input" && rich.selected == b && rich.text == "Second",
      "Final rendered update after navigation saves only its original document")
    try "External edits".write(to: a, atomically: true, encoding: .utf8)
    rich.renderedEdit(url: a, base: "Final input", value: "Conflicting input")
    let externalRich = try String(contentsOf: a, encoding: .utf8)
    check(
      externalRich == "External edits" && rich.error != nil,
      "Late rendered update cannot overwrite an external edit")
    let categoryRoot = FileStore.canonical(root).appendingPathComponent("category-tests")
    for folder in ["10-alpha/nested", "20-beta"] {
      try fm.createDirectory(
        at: categoryRoot.appendingPathComponent(folder), withIntermediateDirectories: true)
    }
    let first = categoryRoot.appendingPathComponent("10-alpha/old.md")
    let second = categoryRoot.appendingPathComponent("20-beta/new.md")
    let nested = categoryRoot.appendingPathComponent("10-alpha/nested/child.md")
    try FileStore.create(url: first, text: "Original document content")
    try FileStore.create(url: second, text: "New document")
    try FileStore.create(url: nested, text: "Nested document")
    try fm.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: first.path)
    try fm.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 200)], ofItemAtPath: second.path)
    try fm.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 150)], ofItemAtPath: nested.path)
    let categories = Workspace(rootURL: categoryRoot, startMonitoring: false)
    let original = try FileStore.scan(categoryRoot).files
    let group = FolderGroup(name: "My work", folders: ["10-alpha", "10-alpha/nested"])
    categories.updateGroup(group)
    categories.scope = "group:" + group.id.uuidString
    check(
      categories.visibleFiles.count == 2,
      "Folder group aggregates descendants without duplicating overlaps")
    check(
      categories.visibleFiles.allSatisfy { $0.folder.hasPrefix("10-alpha") },
      "Folder group excludes unrelated folders")
    categories.scope = "groupFolder:" + group.id.uuidString + ":10-alpha/nested"
    check(
      categories.visibleFiles.count == 1 && categories.defaultFolder == "10-alpha/nested",
      "Grouped child folder opens its own contents and creation location")
    categories.toggleFolder("20-beta", in: group.id)
    categories.scope = "group:" + group.id.uuidString
    check(
      categories.visibleFiles.count == 3, "Folder membership can change without moving documents")
    categories.toggleFolder("20-beta", in: FolderGroup.starredID)
    categories.scope = "group:" + FolderGroup.starredID.uuidString
    check(
      categories.visibleFiles.map(\.url) == [second],
      "Starred folders have an independent aggregate")
    let memberships = categories.folderGroups.flatMap(\.folders)
    check(
      Set(memberships).count == memberships.count, "A folder belongs to at most one custom group")
    check(
      !categories.folderGroups.first(where: { $0.id == group.id })!.folders.contains("20-beta"),
      "Moving a folder to starred removes its previous membership")
    check(
      !categories.ungroupedFolders.contains("10-alpha")
        && !categories.ungroupedFolders.contains("20-beta"),
      "Promoted folders disappear from the default folder group")
    categories.assignFolder("20-beta", to: nil)
    check(
      categories.ungroupedFolders.contains("20-beta"),
      "Removing folder membership returns it to the default group")
    categories.assignFolder("20-beta", to: FolderGroup.starredID)
    categories.toggleGroupExpanded(group.id)
    categories.toggleDefaultFolders()
    categories.scope = "all"
    check(
      categories.visibleFiles.first?.url == second,
      "Unpinned documents retain modification-date order")
    categories.togglePin(first)
    check(
      categories.visibleFiles.first?.url == first,
      "Pinned oldest document sorts ahead of newest document")
    categories.search = "New document"
    check(categories.visibleFiles.map(\.url) == [second], "Pinning never bypasses current search")
    categories.search = ""
    categories.scope = "folder:20-beta"
    check(categories.visibleFiles.map(\.url) == [second], "Pinning never bypasses current folder")
    let reloaded = Workspace(rootURL: categoryRoot, startMonitoring: false)
    check(
      reloaded.folderGroups == categories.folderGroups && reloaded.isPinned(first),
      "Folder groups and pins persist across restart")
    check(
      reloaded.collapsedGroups.contains(group.id) && reloaded.defaultFoldersCollapsed,
      "Custom and default group expansion states survive restart")
    let afterCategorization = try FileStore.scan(categoryRoot).files
    check(
      afterCategorization == original,
      "Grouping and pinning do not change file paths, contents, or modification dates")
    check(
      !Workspace(rootURL: richRoot, startMonitoring: false).isPinned(first),
      "Pins and groups are scoped to each workspace")
    categories.select(first)
    check(
      categories.relocate(name: "renamed.md", folder: "20-beta"),
      "Pinned document can be renamed and moved")
    let renamed = categories.selected!
    check(
      categories.isPinned(renamed) && !categories.isPinned(first),
      "Pin follows an in-app rename and move")
    check(
      categories.moveDocument(renamed, to: "10-alpha"), "Pinned document can change status quickly")
    check(categories.isPinned(categories.selected!), "Pin follows a quick state-folder move")
    categories.togglePin(categories.selected!)
    check(!categories.isPinned(categories.selected!), "Unpin removes the app-only designation")
    categories.scope = "groupFolder:" + group.id.uuidString + ":10-alpha"
    categories.deleteGroup(group)
    check(
      categories.scope == "all" && fm.fileExists(atPath: nested.path),
      "Deleting a group preserves its folders and resets its child selection")
    check(
      categories.ungroupedFolders.contains("10-alpha")
        && categories.ungroupedFolders.contains("10-alpha/nested"),
      "Deleting a group returns its folders to the default group")
    UserDefaults.standard.removeObject(
      forKey: "folderGroups:" + FileStore.canonical(categoryRoot).path + ":collapsed")
    UserDefaults.standard.removeObject(
      forKey: "folderGroups:" + FileStore.canonical(categoryRoot).path + ":defaultCollapsed")
    UserDefaults.standard.removeObject(
      forKey: "folderGroups:" + FileStore.canonical(categoryRoot).path)
    UserDefaults.standard.removeObject(
      forKey: "pinnedDocuments:" + FileStore.canonical(categoryRoot).path)
    print("\(count) model checks passed")
  }
}
