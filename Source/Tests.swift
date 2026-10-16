import Foundation

@main struct CoreTests {
  static func main() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "MattersTests-" + UUID().uuidString)
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("01-someday"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("02-identified"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var checks = 0
    func check(_ condition: @autoclosure () -> Bool, _ name: String) {
      precondition(condition(), name)
      checks += 1
      print("PASS: " + name)
    }
    func mustThrow(_ name: String, _ action: () throws -> Void) {
      do {
        try action()
        fatalError("Expected failure: " + name)
      } catch {
        checks += 1
        print("PASS: " + name)
      }
    }
    let original =
      "---\nurgency: high\ncustom_field: any value\n---\n\n# Free-form content\n\n- [ ] Review\nCode is free-form too: `a: b`\n"
    let url = try FileStore.child(root: root, folder: "01-someday", name: "matter.md")
    try FileStore.create(url: url, text: original)
    let initial = try Data(contentsOf: url)
    check(initial == Data(original.utf8), "Creation preserves exact content; no metadata insertion")
    try Data([0, 1, 2]).write(to: root.appendingPathComponent("binary.bin"))
    try "free text".write(
      to: root.appendingPathComponent("no-extension"), atomically: true, encoding: .utf8)
    let result = try FileStore.scan(root)
    check(
      result.files.count == 2 && result.skipped == 1,
      "Any UTF-8 text filename accepted; binary skipped")
    check(tryData(url) == initial, "Scanning never modifies documents")
    guard let doc = result.files.first(where: { $0.url.path == url.path }) else {
      fatalError("Missing \(url.path); found \(result.files.map { $0.url.path })")
    }
    check(Rule(value: "urgency: high").matches(doc), "Arbitrary metadata searched as plain text")
    check(Rule(target: .path, value: "someday").matches(doc), "Folder filter")
    check(
      Rule(target: .filename, operation: .equals, value: "matter.md").matches(doc),
      "Filename equality")
    check(
      Rule(operation: .regex, value: "(?m)^urgency:\\s*high$").matches(doc),
      "Regex supports multiline text")
    check(Rule(operation: .regex, value: "[").error != nil, "Invalid regular expression reported")
    check(!SavedView(rules: []).matches(doc), "Empty rules cannot accidentally match everything")
    let view = SavedView(
      name: "Custom saved view",
      rules: [Rule(value: "urgency: high"), Rule(value: "Missing phrase")])
    check(!view.matches(doc), "All conditions required")
    var anyView = view
    anyView.matchAll = false
    check(anyView.matches(doc), "Any condition supported")
    let encoded = try JSONEncoder().encode(anyView)
    let decoded = try JSONDecoder().decode(SavedView.self, from: encoded)
    check(decoded == anyView, "Custom views persist without document schema")
    try mustCreateConflict(url, original)
    checks += 1
    print("PASS: Duplicate creation does not overwrite")
    let updated = original + "New content\n"
    let newBaseline = try FileStore.save(url: url, text: updated, baseline: initial)
    check(newBaseline == tryData(url), "Edit saved byte-for-byte")
    let external = "Written by an external editor\n"
    try Data(external.utf8).write(to: url)
    mustThrow("External edits are not silently overwritten") {
      _ = try FileStore.save(url: url, text: "App edits", baseline: newBaseline)
    }
    check(tryData(url) == Data(external.utf8), "External content retained after conflict")
    let moved = try FileStore.child(root: root, folder: "02-identified", name: "matter.md")
    try FileManager.default.moveItem(at: url, to: moved)
    mustThrow("Externally moved file is not recreated on save") {
      _ = try FileStore.save(url: url, text: "App edits", baseline: newBaseline)
    }
    let afterMove = try FileStore.scan(root)
    check(
      afterMove.files.first { $0.url == moved }?.folder == "02-identified",
      "External folder moves recognized")
    mustThrow("Path traversal rejected") {
      _ = try FileStore.child(root: root, folder: "../../", name: "escape.md")
    }
    mustThrow("Invalid filename rejected") {
      _ = try FileStore.child(root: root, folder: ".", name: "a/b")
    }
    print("\(checks) checks passed")
  }
  static func tryData(_ url: URL) -> Data { (try? Data(contentsOf: url)) ?? Data() }
  static func mustCreateConflict(_ url: URL, _ original: String) throws {
    do {
      try FileStore.create(url: url, text: "overwrite")
      fatalError("Creation replaced a file")
    } catch {}
    precondition(tryData(url) == Data(original.utf8))
  }
}
