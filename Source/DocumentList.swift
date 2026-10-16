import AppKit
import SwiftUI

// Let AppKit arbitrate a row click vs. a drag. The editor selection is independent
// of SwiftUI List's transient nil selections during refreshes and file moves.
struct DocumentList: NSViewRepresentable {
  @ObservedObject var model: Workspace

  func makeCoordinator() -> Coordinator { Coordinator(model: model) }

  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.drawsBackground = false
    let table = DocumentTable()
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("document"))
    column.resizingMask = .autoresizingMask
    table.addTableColumn(column)
    table.headerView = nil
    table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
    table.rowHeight = 96
    table.intercellSpacing = NSSize(width: 0, height: 1)
    table.allowsMultipleSelection = false
    table.allowsEmptySelection = true
    table.style = .plain
    table.selectionHighlightStyle = .regular
    table.backgroundColor = .clear
    table.delegate = context.coordinator
    table.dataSource = context.coordinator
    table.contextMenuForRow = { [weak coordinator = context.coordinator] row in
      coordinator?.menu(for: row)
    }
    table.setDraggingSourceOperationMask(.move, forLocal: true)
    table.setDraggingSourceOperationMask(.copy, forLocal: false)
    table.setAccessibilityLabel("문서 목록")
    scroll.documentView = table
    context.coordinator.table = table
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    let coordinator = context.coordinator
    coordinator.model = model
    let documents = model.visibleFiles
    coordinator.updating = true
    if coordinator.documents != documents || coordinator.pins != model.pinnedDocuments {
      coordinator.pins = model.pinnedDocuments
      coordinator.documents = documents
      coordinator.table?.reloadData()
    }
    coordinator.restoreSelection()
    coordinator.updating = false
  }

  @MainActor final class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource {
    var model: Workspace
    var documents: [ProblemFile] = []
    var pins: Set<String> = []
    weak var table: NSTableView?
    var updating = false
    init(model: Workspace) { self.model = model }

    func numberOfRows(in tableView: NSTableView) -> Int { documents.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
      -> NSView?
    {
      guard documents.indices.contains(row) else { return nil }
      let id = NSUserInterfaceItemIdentifier("documentCell")
      let cell =
        (tableView.makeView(withIdentifier: id, owner: self) as? DocumentCell) ?? DocumentCell()
      cell.identifier = id
      cell.configure(documents[row], pinned: model.isPinned(documents[row].url))
      return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
      guard !updating, let table else { return }
      open(row: table.selectedRow)
    }
    func open(row: Int) {
      guard documents.indices.contains(row) else { return }
      model.select(documents[row].url)
      // A save conflict may refuse navigation: keep the highlight on the
      // document whose edit buffer is actually open.
      updating = true
      restoreSelection()
      updating = false
    }
    func restoreSelection() {
      guard let table else { return }
      let row = documents.firstIndex { $0.url.path == model.selected?.path }
      if let row {
        if table.selectedRow != row {
          table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
      } else if table.selectedRow != -1 {
        table.deselectAll(nil)
      }
    }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int)
      -> NSPasteboardWriting?
    {
      guard documents.indices.contains(row) else { return nil }
      return documents[row].url as NSURL
    }
    func menu(for row: Int) -> NSMenu? {
      guard documents.indices.contains(row) else { return nil }
      let document = documents[row]
      let menu = NSMenu()
      let pin = NSMenuItem(
        title: model.isPinned(document.url) ? "📌 고정 해제" : "📌 맨 위에 고정",
        action: #selector(pinFromMenu(_:)), keyEquivalent: "")
      pin.target = self
      pin.representedObject = document.url
      menu.addItem(pin)
      menu.addItem(.separator())
      let moveItem = NSMenuItem(title: "상태 변경", action: nil, keyEquivalent: "")
      let destinations = NSMenu()
      for folder in model.folders {
        let item = NSMenuItem(
          title: folder == "." ? "최상위 폴더" : folder, action: #selector(moveFromMenu(_:)),
          keyEquivalent: "")
        item.target = self
        item.representedObject = ["path": document.url.path, "folder": folder]
        if folder == document.folder {
          item.state = .on
          item.isEnabled = false
        }
        destinations.addItem(item)
      }
      destinations.autoenablesItems = false
      moveItem.submenu = destinations
      menu.addItem(moveItem)
      let reveal = NSMenuItem(
        title: "Finder에서 보기", action: #selector(revealFromMenu(_:)), keyEquivalent: "")
      reveal.target = self
      reveal.representedObject = document.url
      menu.addItem(reveal)
      return menu
    }
    @objc func pinFromMenu(_ sender: NSMenuItem) {
      if let url = sender.representedObject as? URL { model.togglePin(url) }
    }
    @objc func moveFromMenu(_ sender: NSMenuItem) {
      guard let payload = sender.representedObject as? [String: String], let path = payload["path"],
        let folder = payload["folder"]
      else { return }
      model.moveDocument(URL(fileURLWithPath: path), to: folder)
    }
    @objc func revealFromMenu(_ sender: NSMenuItem) {
      if let url = sender.representedObject as? URL {
        NSWorkspace.shared.activateFileViewerSelecting([url])
      }
    }
  }
}

final class DocumentTable: NSTableView {
  var contextMenuForRow: ((Int) -> NSMenu?)?
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func menu(for event: NSEvent) -> NSMenu? {
    let row = self.row(at: convert(event.locationInWindow, from: nil))
    return contextMenuForRow?(row)
  }
}

final class DocumentCell: NSTableCellView {
  private let titleLabel = NSTextField(labelWithString: "")
  private let previewLabel = NSTextField(labelWithString: "")
  private let locationLabel = NSTextField(labelWithString: "")
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
    previewLabel.font = .systemFont(ofSize: 12)
    locationLabel.font = .systemFont(ofSize: 10)
    for label in [titleLabel, previewLabel, locationLabel] {
      label.lineBreakMode = .byTruncatingTail
      label.maximumNumberOfLines = 1
      label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    let stack = NSStackView(views: [titleLabel, previewLabel, locationLabel])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 7
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
      stack.centerYAnchor.constraint(equalTo: centerYAnchor),
      titleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
      previewLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
      locationLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
    ])
    textField = titleLabel
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override var backgroundStyle: NSView.BackgroundStyle { didSet { updateColors() } }
  private func updateColors() {
    let selected = backgroundStyle == .emphasized
    titleLabel.textColor = selected ? .alternateSelectedControlTextColor : .labelColor
    previewLabel.textColor = selected ? .alternateSelectedControlTextColor : .secondaryLabelColor
    locationLabel.textColor = selected ? .alternateSelectedControlTextColor : .tertiaryLabelColor
  }
  func configure(_ document: ProblemFile, pinned: Bool) {
    titleLabel.stringValue = (pinned ? "📌 " : "") + document.title
    previewLabel.stringValue = document.preview
    locationLabel.stringValue =
      (document.folder == "." ? "최상위 폴더" : document.folder) + " · "
      + document.modified.formatted(date: .numeric, time: .omitted)
    toolTip = document.relativePath
    setAccessibilityLabel((pinned ? "📌 " : "") + document.title)
    updateColors()
  }
}
