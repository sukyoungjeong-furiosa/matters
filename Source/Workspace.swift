import AppKit
import Combine
import Foundation

@MainActor final class Workspace: ObservableObject {
  @Published var root: URL
  @Published var files: [ProblemFile] = []
  @Published var folders: [String] = ["."]
  @Published var savedViews: [SavedView] = []
  @Published var folderGroups: [FolderGroup] = []
  @Published var pinnedDocuments: Set<String> = []
  @Published var editingGroup: FolderGroup?
  @Published var collapsedGroups: Set<UUID> = []
  @Published var defaultFoldersCollapsed = false
  @Published var scope = "all"
  @Published var selected: URL?
  @Published var text = ""
  @Published var search = ""
  @Published var dirty = false
  @Published var conflict = false
  @Published var message = ""
  @Published var error: String?
  @Published var skipped = 0
  @Published var showNew = false
  @Published var showMove = false
  @Published var showRename = false
  @Published var editingView: SavedView?
  @Published var sortByName = false
  @Published var renderedMode = true
  var flushRenderedEdits: (() async -> Void)?
  var renderedCommand: ((String) -> Void)?
  private var baseline = Data()
  private var saveTask: Task<Void, Never>?
  private var timer: AnyCancellable?
  private var loading = false
  private var pinKey: String { "pinnedDocuments:" + root.path }
  private var groupKey: String { "folderGroups:" + root.path }
  private var viewKey: String { "views:" + root.path }

  init(rootURL: URL? = nil, startMonitoring: Bool = true) {
    let defaultRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "Documents/matters")
    root = FileStore.canonical(
      rootURL ?? UserDefaults.standard.string(forKey: "workspace").map { URL(fileURLWithPath: $0) }
        ?? defaultRoot)
    readViews()
    readGroups()
    refresh()
    if startMonitoring {
      timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect().sink { [weak self] _ in
        self?.refresh()
      }
    }
  }
  var visibleFiles: [ProblemFile] {
    files.filter { file in
      let scoped: Bool
      if let path = activeFolder {
        scoped =
          path == "."
          ? file.folder == "." : file.folder == path || file.folder.hasPrefix(path + "/")
      } else if let group = activeGroup {
        scoped = group.includes(file)
      } else if scope.hasPrefix("view:"), let view = activeView {
        scoped = view.matches(file)
      } else {
        scoped = true
      }
      let searched =
        search.isEmpty || file.relativePath.localizedCaseInsensitiveContains(search)
        || file.content.localizedCaseInsensitiveContains(search)
      return scoped && searched
    }.sorted {
      let leftPinned = pinnedDocuments.contains($0.relativePath)
      let rightPinned = pinnedDocuments.contains($1.relativePath)
      if leftPinned != rightPinned { return leftPinned }
      if sortByName {
        return $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
      }
      if $0.modified == $1.modified { return $0.relativePath < $1.relativePath }
      return $0.modified > $1.modified
    }
  }
  var activeFolder: String? {
    if scope.hasPrefix("folder:") { return String(scope.dropFirst(7)) }
    if scope.hasPrefix("groupFolder:") {
      return scope.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).last.map(
        String.init)
    }
    return nil
  }
  var activeGroup: FolderGroup? { folderGroups.first { "group:" + $0.id.uuidString == scope } }
  var activeView: SavedView? { savedViews.first { "view:" + $0.id.uuidString == scope } }
  var scopeTitle: String {
    if let group = activeGroup { return group.name }
    if let view = activeView { return view.name }
    if let path = activeFolder {
      return path == "." ? "최상위 문서" : (path as NSString).lastPathComponent
    }
    return "전체 문제"
  }
  var defaultFolder: String {
    activeFolder ?? activeGroup?.folders.first(where: { folders.contains($0) }) ?? folders.first(
      where: { $0 != "." }) ?? "."
  }
  func refresh() {
    do {
      let result = try FileStore.scan(root)
      files = result.files
      folders = result.folders
      skipped = result.skipped
      if let selected {
        if let data = try? Data(contentsOf: selected), data != baseline {
          if dirty {
            conflict = true
            message = "외부 변경 감지 · 편집본 보존 중"
          } else if let fresh = String(data: data, encoding: .utf8) {
            loading = true
            text = fresh
            baseline = data
            loading = false
            message = "외부 변경 반영됨"
          }
        } else if !FileManager.default.fileExists(atPath: selected.path) {
          conflict = true
          message = "파일이 외부에서 이동되거나 삭제됨 · 편집본 보존 중"
        }
      }
    } catch { message = "폴더를 읽을 수 없습니다: \(error.localizedDescription)" }
  }
  private var selectionRequest = UUID()
  func changeMode(_ rendered: Bool) {
    guard renderedMode != rendered else { return }
    if renderedMode, let flush = flushRenderedEdits {
      Task { @MainActor in
        await flush()
        renderedMode = rendered
      }
    } else {
      renderedMode = rendered
    }
  }
  func select(_ url: URL?) {
    guard url != selected else { return }
    selectionRequest = UUID()
    let request = selectionRequest
    if renderedMode, let flush = flushRenderedEdits {
      Task { @MainActor in
        await flush()
        guard request == selectionRequest else { return }
        selectNow(url)
      }
    } else {
      selectNow(url)
    }
  }
  private func selectNow(_ url: URL?) {
    guard url != selected else { return }
    guard save() else { return }
    guard let url else {
      selected = nil
      text = ""
      return
    }
    do {
      let data = try Data(contentsOf: url)
      guard let value = String(data: data, encoding: .utf8) else {
        throw CocoaError(.fileReadInapplicableStringEncoding)
      }
      loading = true
      selected = url
      baseline = data
      text = value
      dirty = false
      conflict = false
      message = "저장됨"
      loading = false
    } catch { self.error = error.localizedDescription }
  }
  func renderedEdit(url: URL, base: String, value: String) {
    if selected == url {
      guard text == base else { return }
      edited(value)
    } else {
      // A final WebKit message can arrive just after navigation. Save with
      // the same compare-and-swap protection as the active document.
      do {
        _ = try FileStore.save(url: url, text: value, baseline: Data(base.utf8))
        refresh()
      } catch { self.error = "문서 편집 내용을 저장하지 못했습니다: \(error.localizedDescription)" }
    }
  }
  func edited(_ value: String) {
    text = value
    guard !loading, selected != nil else { return }
    dirty = Data(value.utf8) != baseline
    message = dirty ? "편집 중…" : "저장됨"
    saveTask?.cancel()
    guard dirty, !conflict else { return }
    saveTask = Task { [weak self] in
      do { try await Task.sleep(nanoseconds: 800_000_000) } catch { return }
      _ = self?.save(reportError: false)
    }
  }
  @discardableResult func save(reportError: Bool = true) -> Bool {
    saveTask?.cancel()
    guard dirty, let selected else { return true }
    do {
      baseline = try FileStore.save(url: selected, text: text, baseline: baseline)
      dirty = false
      conflict = false
      message = "저장됨"
      refresh()
      return true
    } catch {
      conflict = true
      message = error.localizedDescription
      if reportError { self.error = error.localizedDescription }
      return false
    }
  }
  func reloadExternal() {
    guard let selected else { return }
    if dirty {
      let alert = NSAlert()
      alert.messageText = "편집 내용을 버리고 외부 파일을 불러올까요?"
      alert.informativeText = "남길 내용이 있다면 먼저 ‘편집본 별도 저장’을 사용하세요."
      alert.addButton(withTitle: "취소")
      alert.addButton(withTitle: "불러오기")
      guard alert.runModal() == .alertSecondButtonReturn else { return }
    }
    do {
      let data = try Data(contentsOf: selected)
      guard let fresh = String(data: data, encoding: .utf8) else {
        throw CocoaError(.fileReadInapplicableStringEncoding)
      }
      saveTask?.cancel()
      baseline = data
      text = fresh
      dirty = false
      conflict = false
      message = "외부 변경 반영됨"
      refresh()
    } catch { self.error = error.localizedDescription }
  }
  func saveCopy() {
    let panel = NSSavePanel()
    panel.title = "현재 편집본을 별도 파일로 저장"
    panel.nameFieldStringValue =
      (selected?.deletingPathExtension().lastPathComponent ?? "문제") + " 복사본.md"
    panel.directoryURL = selected?.deletingLastPathComponent() ?? root
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      // NSSavePanel explicitly confirms replacement of an existing destination.
      try Data(text.utf8).write(to: url, options: .atomic)
      if url == selected {
        baseline = Data(text.utf8)
        dirty = false
        conflict = false
      }
      message = "편집본 별도 저장됨"
      refresh()
    } catch { self.error = error.localizedDescription }
  }
  func create(name: String, folder: String, body: String) -> Bool {
    guard save() else { return false }
    do {
      let url = try FileStore.child(root: root, folder: folder, name: name)
      try FileStore.create(url: url, text: body)
      scope = "folder:" + folder
      search = ""
      renderedMode = true
      refresh()
      select(url)
      return true
    } catch {
      self.error = error.localizedDescription
      return false
    }
  }
  func relocate(name: String, folder: String) -> Bool {
    guard let selected, save() else { return false }
    do {
      let destination = try FileStore.child(root: root, folder: folder, name: name)
      if destination == selected { return true }
      guard !FileManager.default.fileExists(atPath: destination.path) else {
        throw FileIssue.exists
      }
      try FileManager.default.moveItem(at: selected, to: destination)
      migratePin(from: selected, to: destination)
      self.selected = destination
      scope = "folder:" + folder
      search = ""
      refresh()
      return true
    } catch {
      self.error = error.localizedDescription
      return false
    }
  }
  @discardableResult func moveDocument(_ url: URL, to folder: String) -> Bool {
    let source = FileStore.canonical(url)
    guard source.isFileURL, files.contains(where: { $0.url.path == source.path }),
      folders.contains(folder)
    else {
      error = "현재 작업 폴더의 문서만 상태 폴더로 옮길 수 있습니다."
      return false
    }
    let isSelected = selected?.path == source.path
    if isSelected, !save() { return false }
    do {
      let destination = try FileStore.child(
        root: root, folder: folder, name: source.lastPathComponent)
      if destination.path == source.path { return true }
      guard !FileManager.default.fileExists(atPath: destination.path) else {
        throw FileIssue.exists
      }
      try FileManager.default.moveItem(at: source, to: destination)
      migratePin(from: source, to: destination)
      if isSelected { selected = destination }
      // Keep the current list/filter so moving one item does not interrupt triage.
      refresh()
      message = "\(folder == "." ? "최상위 폴더" : folder)로 이동됨"
      return true
    } catch {
      self.error = error.localizedDescription
      return false
    }
  }
  func chooseRoot() {
    guard save() else { return }
    let panel = NSOpenPanel()
    panel.title = "문제를 담을 폴더 선택"
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.directoryURL = root
    guard panel.runModal() == .OK, let url = panel.url else { return }
    selected = nil
    text = ""
    dirty = false
    conflict = false
    search = ""
    root = FileStore.canonical(url)
    scope = "all"
    UserDefaults.standard.set(root.path, forKey: "workspace")
    readViews()
    readGroups()
    refresh()
  }
  func documentPath(_ url: URL) -> String? {
    let path = FileStore.canonical(url).path
    let prefix = root.path + "/"
    guard path.hasPrefix(prefix) else { return nil }
    return String(path.dropFirst(prefix.count))
  }
  func isPinned(_ url: URL) -> Bool {
    documentPath(url).map { pinnedDocuments.contains($0) } ?? false
  }
  func togglePin(_ url: URL) {
    guard let path = documentPath(url), files.contains(where: { $0.relativePath == path }) else {
      return
    }
    if pinnedDocuments.contains(path) {
      pinnedDocuments.remove(path)
    } else {
      pinnedDocuments.insert(path)
    }
    persistPins()
  }
  func persistPins() { UserDefaults.standard.set(pinnedDocuments.sorted(), forKey: pinKey) }
  func migratePin(from source: URL, to destination: URL) {
    guard let old = documentPath(source), let new = documentPath(destination),
      pinnedDocuments.remove(old) != nil
    else { return }
    pinnedDocuments.insert(new)
    persistPins()
  }
  var ungroupedFolders: [String] {
    let assigned = Set(folderGroups.flatMap(\.folders))
    return folders.filter { !assigned.contains($0) }
  }
  func toggleGroupExpanded(_ id: UUID) {
    if collapsedGroups.contains(id) {
      collapsedGroups.remove(id)
    } else {
      collapsedGroups.insert(id)
    }
    persistGroupLayout()
  }
  func toggleDefaultFolders() {
    defaultFoldersCollapsed.toggle()
    persistGroupLayout()
  }
  func persistGroupLayout() {
    UserDefaults.standard.set(
      collapsedGroups.map(\.uuidString).sorted(), forKey: groupKey + ":collapsed")
    UserDefaults.standard.set(defaultFoldersCollapsed, forKey: groupKey + ":defaultCollapsed")
  }
  func readGroups() {
    collapsedGroups = Set(
      (UserDefaults.standard.stringArray(forKey: groupKey + ":collapsed") ?? []).compactMap(
        UUID.init(uuidString:)))
    defaultFoldersCollapsed = UserDefaults.standard.bool(forKey: groupKey + ":defaultCollapsed")
    pinnedDocuments = Set(UserDefaults.standard.stringArray(forKey: pinKey) ?? [])
    if let data = UserDefaults.standard.data(forKey: groupKey),
      let groups = try? JSONDecoder().decode([FolderGroup].self, from: data)
    {
      folderGroups = groups
    } else {
      folderGroups = [FolderGroup(id: FolderGroup.starredID, name: "즐겨찾기")]
    }
    // Migrate any earlier overlapping groups: each exact folder has one owner.
    var claimed = Set<String>()
    for index in folderGroups.indices.reversed() {
      folderGroups[index].folders = folderGroups[index].folders.filter {
        claimed.insert($0).inserted
      }
    }
  }
  func persistGroups() {
    if let data = try? JSONEncoder().encode(folderGroups) {
      UserDefaults.standard.set(data, forKey: groupKey)
    }
  }
  func updateGroup(_ draft: FolderGroup) {
    var group = draft
    group.name = group.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !group.name.isEmpty else { return }
    group.folders = Array(Set(group.folders)).sorted {
      $0.localizedStandardCompare($1) == .orderedAscending
    }
    let assigned = Set(group.folders)
    for index in folderGroups.indices where folderGroups[index].id != group.id {
      folderGroups[index].folders.removeAll { assigned.contains($0) }
    }
    if let index = folderGroups.firstIndex(where: { $0.id == group.id }) {
      folderGroups[index] = group
    } else {
      folderGroups.append(group)
    }
    persistGroups()
    reconcileFolderScope()
  }
  func reconcileFolderScope() {
    guard let folder = activeFolder else { return }
    if let owner = folderGroups.first(where: { $0.folders.contains(folder) }) {
      scope = "groupFolder:" + owner.id.uuidString + ":" + folder
    } else {
      scope = "folder:" + folder
    }
  }
  func assignFolder(_ folder: String, to groupID: UUID?) {
    guard folders.contains(folder),
      groupID == nil || folderGroups.contains(where: { $0.id == groupID })
    else { return }
    for index in folderGroups.indices {
      folderGroups[index].folders.removeAll { $0 == folder }
      if folderGroups[index].id == groupID { folderGroups[index].folders.append(folder) }
    }
    persistGroups()
    reconcileFolderScope()
  }
  func toggleFolder(_ folder: String, in groupID: UUID) {
    let current = folderGroups.first(where: { $0.id == groupID })?.folders.contains(folder) == true
    assignFolder(folder, to: current ? nil : groupID)
  }
  func deleteGroup(_ group: FolderGroup) {
    folderGroups.removeAll { $0.id == group.id }
    persistGroups()
    if scope == "group:" + group.id.uuidString
      || scope.hasPrefix("groupFolder:" + group.id.uuidString + ":")
    {
      scope = "all"
    }
  }
  func readViews() {
    savedViews =
      UserDefaults.standard.data(forKey: viewKey).flatMap {
        try? JSONDecoder().decode([SavedView].self, from: $0)
      } ?? []
  }
  func updateView(_ view: SavedView) {
    if let index = savedViews.firstIndex(where: { $0.id == view.id }) {
      savedViews[index] = view
    } else {
      savedViews.append(view)
    }
    persistViews()
    scope = "view:" + view.id.uuidString
  }
  func deleteView(_ view: SavedView) {
    savedViews.removeAll { $0.id == view.id }
    persistViews()
    if scope == "view:" + view.id.uuidString { scope = "all" }
  }
  func persistViews() {
    if let data = try? JSONEncoder().encode(savedViews) {
      UserDefaults.standard.set(data, forKey: viewKey)
    }
  }
  func format(_ command: MarkdownCommand) {
    if renderedMode {
      renderedCommand?(
        command == .bold ? "toggleBold" : command == .italic ? "toggleItalic" : "toggleCodeBlock")
      return
    }
    guard selected != nil, let window = NSApp.keyWindow, window.sheetParent == nil else { return }
    guard let editor = window.firstResponder as? NSTextView,
      editor.isEditable, !editor.isFieldEditor, editor.string == text
    else { return }
    if editor.hasMarkedText() { editor.unmarkText() }
    guard
      let change = MarkdownEditing.change(
        in: editor.string, selection: editor.selectedRange(), command: command)
    else { return }
    editor.breakUndoCoalescing()
    guard
      editor.performValidatedReplacement(
        in: change.range, with: NSAttributedString(string: change.replacement))
    else { return }
    editor.setSelectedRange(change.selection)
    editor.scrollRangeToVisible(change.selection)
    editor.breakUndoCoalescing()
    editor.undoManager?.setActionName(command.title)
  }
  func reveal() { NSWorkspace.shared.activateFileViewerSelecting([selected ?? root]) }
}
