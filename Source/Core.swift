import Darwin
import Foundation

enum RuleTarget: String, Codable, CaseIterable {
  case content, filename, path
  var title: String {
    switch self {
    case .content: return "문서 내용"
    case .filename: return "파일 이름"
    case .path: return "폴더 경로"
    }
  }
}
enum RuleOperation: String, Codable, CaseIterable {
  case contains, notContains, equals, regex
  var title: String {
    switch self {
    case .contains: return "포함"
    case .notContains: return "포함하지 않음"
    case .equals: return "일치"
    case .regex: return "정규식"
    }
  }
}
struct Rule: Codable, Identifiable, Equatable {
  var id = UUID()
  var target: RuleTarget = .content
  var operation: RuleOperation = .contains
  var value = ""
  var caseSensitive = false
  var error: String? {
    if value.isEmpty { return "조건에 찾을 내용을 입력해 주세요." }
    if operation == .regex {
      do { _ = try NSRegularExpression(pattern: value) } catch {
        return "정규식이 올바르지 않습니다: \(error.localizedDescription)"
      }
    }
    return nil
  }
  func matches(_ document: ProblemFile) -> Bool {
    guard error == nil else { return false }
    let source: String
    switch target {
    case .content: source = document.content
    case .filename: source = document.url.lastPathComponent
    case .path: source = document.folder
    }
    let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
    switch operation {
    case .contains: return source.range(of: value, options: options) != nil
    case .notContains: return source.range(of: value, options: options) == nil
    case .equals: return source.compare(value, options: options) == .orderedSame
    case .regex:
      guard
        let expression = try? NSRegularExpression(
          pattern: value, options: caseSensitive ? [] : [.caseInsensitive])
      else { return false }
      return expression.firstMatch(in: source, range: NSRange(source.startIndex..., in: source))
        != nil
    }
  }
}
struct SavedView: Codable, Identifiable, Equatable {
  var id = UUID()
  var name = "새 모아보기"
  var matchAll = true
  var rules = [Rule()]
  func matches(_ document: ProblemFile) -> Bool {
    guard !rules.isEmpty, rules.allSatisfy({ $0.error == nil }) else { return false }
    return matchAll
      ? rules.allSatisfy { $0.matches(document) } : rules.contains { $0.matches(document) }
  }
}
struct ProblemFile: Identifiable, Equatable {
  var id: String { url.path }
  let url: URL
  let relativePath: String
  let content: String
  let modified: Date
  var folder: String {
    let parent = (relativePath as NSString).deletingLastPathComponent
    return parent.isEmpty ? "." : parent
  }
  var title: String { url.deletingPathExtension().lastPathComponent }
  var preview: String {
    content.split(whereSeparator: \.isNewline).prefix(4).joined(separator: " ").prefix(180)
      .description
  }
}
enum FileIssue: LocalizedError {
  case conflict, missing, invalidName, exists, outsideRoot
  var errorDescription: String? {
    switch self {
    case .conflict: return "다른 앱에서 파일이 변경되었습니다. 편집 내용을 복사하거나 별도 파일로 저장한 뒤 외부 변경을 불러올 수 있습니다."
    case .missing: return "파일이 외부에서 이동되었거나 삭제되었습니다. 현재 편집 내용을 새 파일로 저장할 수 있습니다."
    case .invalidName: return "파일 이름은 비어 있거나 /, :, 줄바꿈을 포함할 수 없습니다. 숨김 파일 이름도 사용할 수 없습니다."
    case .exists: return "같은 이름의 파일이 이미 있습니다. 다른 이름을 입력해 주세요."
    case .outsideRoot: return "작업 폴더 안의 위치를 선택해 주세요."
    }
  }
}
enum FileStore {
  static func canonical(_ url: URL) -> URL {
    guard let path = realpath(url.path, nil) else { return url.standardizedFileURL }
    defer { free(path) }
    return URL(fileURLWithFileSystemRepresentation: path, isDirectory: false, relativeTo: nil)
  }
  static func scan(_ root: URL) throws -> (files: [ProblemFile], folders: [String], skipped: Int) {
    let root = canonical(root)
    var scanError: Error?
    guard
      let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [
          .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey,
          .fileSizeKey,
        ], options: [.skipsHiddenFiles, .skipsPackageDescendants],
        errorHandler: { _, error in
          scanError = error
          return true
        })
    else { throw CocoaError(.fileReadNoSuchFile) }
    var files: [ProblemFile] = []
    var folders = ["."]
    var skipped = 0
    for case let url as URL in enumerator {
      let info = try url.resourceValues(forKeys: [
        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey,
        .fileSizeKey,
      ])
      if info.isSymbolicLink == true {
        enumerator.skipDescendants()
        continue
      }
      let relative = String(url.path.dropFirst(root.path.count + 1))
      if info.isDirectory == true {
        folders.append(relative)
        continue
      }
      guard info.isRegularFile == true else { continue }
      guard (info.fileSize ?? 0) <= 10_000_000, let data = try? Data(contentsOf: url),
        !data.contains(0), let content = String(data: data, encoding: .utf8)
      else {
        skipped += 1
        continue
      }
      files.append(
        ProblemFile(
          url: url, relativePath: relative, content: content,
          modified: info.contentModificationDate ?? .distantPast))
    }
    if let scanError { throw scanError }
    return (files, folders.sorted { $0.localizedStandardCompare($1) == .orderedAscending }, skipped)
  }
  static func child(root: URL, folder: String, name: String) throws -> URL {
    let root = canonical(root)
    let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty, !clean.hasPrefix("."),
      clean.rangeOfCharacter(from: CharacterSet(charactersIn: "/:\n\r")) == nil
    else { throw FileIssue.invalidName }
    let directory = folder == "." ? root : root.appendingPathComponent(folder)
    let url = canonical(directory).appendingPathComponent(clean)
    let resolved = canonical(url).path
    guard resolved.hasPrefix(root.path + "/") else { throw FileIssue.outsideRoot }
    return url
  }
  static func create(url: URL, text: String) throws {
    // Exclusive creation prevents replacing a file created concurrently in another app.
    try Data(text.utf8).write(to: url, options: .withoutOverwriting)
  }
  static func save(url: URL, text: String, baseline: Data) throws -> Data {
    guard FileManager.default.fileExists(atPath: url.path) else { throw FileIssue.missing }
    let current = try Data(contentsOf: url)
    guard current == baseline else { throw FileIssue.conflict }
    let updated = Data(text.utf8)
    try updated.write(to: url, options: .atomic)
    return updated
  }
}

// App-only organization. Relative folder paths never become document metadata.
struct FolderGroup: Codable, Identifiable, Equatable {
  static let starredID = UUID(uuidString: "74C641B3-D15E-4AE8-AF16-DA739ED56418")!
  var id = UUID()
  var name = "새 그룹"
  var folders: [String] = []
  var icon: String { id == Self.starredID ? "star" : "square.stack" }
  func includes(_ file: ProblemFile) -> Bool {
    folders.contains { path in
      path == "." ? file.folder == "." : file.folder == path || file.folder.hasPrefix(path + "/")
    }
  }
}
