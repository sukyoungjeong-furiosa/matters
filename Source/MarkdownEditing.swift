import Foundation

enum MarkdownCommand {
  case bold, italic, codeBlock
  var title: String {
    switch self {
    case .bold: return "굵게"
    case .italic: return "기울임"
    case .codeBlock: return "코드 블록"
    }
  }
}
struct MarkdownChange {
  let range: NSRange
  let replacement: String
  let selection: NSRange
  func applied(to text: String) -> String {
    (text as NSString).replacingCharacters(in: range, with: replacement)
  }
}
enum MarkdownEditing {
  static func change(in text: String, selection: NSRange, command: MarkdownCommand)
    -> MarkdownChange?
  {
    guard selection.location != NSNotFound, selection.location <= (text as NSString).length,
      selection.length <= (text as NSString).length - selection.location,
      Range(selection, in: text) != nil
    else { return nil }
    let ns = text as NSString
    for boundary in [selection.location, NSMaxRange(selection)]
    where boundary > 0 && boundary < ns.length {
      let previous = ns.character(at: boundary - 1)
      let next = ns.character(at: boundary)
      if (0xD800...0xDBFF).contains(previous), (0xDC00...0xDFFF).contains(next) { return nil }
    }
    switch command {
    case .bold: return inline(text, selection, marker: "**")
    case .italic: return inline(text, selection, marker: "*")
    case .codeBlock: return codeBlock(text, selection)
    }
  }
  private static func inline(_ text: String, _ selection: NSRange, marker: String) -> MarkdownChange
  {
    let ns = text as NSString
    let count = marker.utf16.count
    let content = ns.substring(with: selection)
    func exactMarkers(_ value: String) -> Bool {
      value.prefix(while: { $0 == "*" }).count == count
        && value.reversed().prefix(while: { $0 == "*" }).count == count
    }
    if selection.length > 2 * count, content.hasPrefix(marker), content.hasSuffix(marker),
      exactMarkers(content)
    {
      let inner = String(content.dropFirst(count).dropLast(count))
      return MarkdownChange(
        range: selection, replacement: inner,
        selection: NSRange(location: selection.location, length: inner.utf16.count))
    }
    let end = NSMaxRange(selection)
    if selection.location >= count, end + count <= ns.length,
      ns.substring(with: NSRange(location: selection.location - count, length: count)) == marker,
      ns.substring(with: NSRange(location: end, length: count)) == marker,
      selection.location == count || ns.character(at: selection.location - count - 1) != 42,
      end + count == ns.length || ns.character(at: end + count) != 42
    {
      let range = NSRange(
        location: selection.location - count, length: selection.length + 2 * count)
      return MarkdownChange(
        range: range, replacement: content,
        selection: NSRange(location: range.location, length: selection.length))
    }
    return MarkdownChange(
      range: selection, replacement: marker + content + marker,
      selection: NSRange(location: selection.location + count, length: selection.length))
  }
  private struct Line {
    let text: String
    let range: NSRange
    let bodyRange: NSRange
  }
  private static func codeBlock(_ text: String, _ selection: NSRange) -> MarkdownChange {
    let ns = text as NSString
    var lines: [Line] = []
    text.enumerateSubstrings(in: text.startIndex..., options: [.byLines]) {
      substring, body, full, _ in
      lines.append(
        Line(
          text: substring ?? "", range: NSRange(full, in: text), bodyRange: NSRange(body, in: text))
      )
    }
    var opening: (line: Line, marker: Character, count: Int)?
    for line in lines {
      let spaces = line.text.prefix(while: { $0 == " " }).count
      guard spaces <= 3 else { continue }
      let stripped = line.text.dropFirst(spaces)
      guard let marker = stripped.first, marker == "`" || marker == "~" else { continue }
      let count = stripped.prefix(while: { $0 == marker }).count
      guard count >= 3 else { continue }
      let tail = stripped.dropFirst(count)
      if let start = opening {
        if marker == start.marker, count >= start.count,
          tail.trimmingCharacters(in: .whitespaces).isEmpty
        {
          let outer = NSRange(
            location: start.line.range.location,
            length: NSMaxRange(line.range) - start.line.range.location)
          if selection.location >= outer.location, selection.location < NSMaxRange(outer),
            NSMaxRange(selection) <= NSMaxRange(outer)
          {
            let innerStart = NSMaxRange(start.line.range)
            var content = ns.substring(
              with: NSRange(location: innerStart, length: line.range.location - innerStart))
            if NSMaxRange(line.range) == NSMaxRange(line.bodyRange) {
              content = removingLastNewline(content)
            }
            let offset = min(max(0, selection.location - innerStart), content.utf16.count)
            let length = min(selection.length, content.utf16.count - offset)
            return MarkdownChange(
              range: outer, replacement: content,
              selection: NSRange(location: outer.location + offset, length: length))
          }
          opening = nil
        }
      } else if marker != "`" || !tail.contains("`") {
        opening = (line, marker, count)
      }
    }
    let range = ns.lineRange(for: selection)
    let original = ns.substring(with: range)
    let newline = text.contains("\r\n") ? "\r\n" : "\n"
    let endedWithNewline =
      original.hasSuffix("\r\n") || original.hasSuffix("\n") || original.hasSuffix("\r")
    let content = removingLastNewline(original)
    var longest = 0
    var current = 0
    for character in content {
      if character == "`" {
        current += 1
        longest = max(longest, current)
      } else {
        current = 0
      }
    }
    let fence = String(repeating: "`", count: max(3, longest + 1))
    let prefix = fence + newline
    let replacement = prefix + content + newline + fence + (endedWithNewline ? newline : "")
    let offset = min(selection.location - range.location, content.utf16.count)
    let length = min(selection.length, content.utf16.count - offset)
    return MarkdownChange(
      range: range, replacement: replacement,
      selection: NSRange(location: range.location + prefix.utf16.count + offset, length: length))
  }
  private static func removingLastNewline(_ text: String) -> String {
    if text.hasSuffix("\r\n") {
      return (text as NSString).substring(to: (text as NSString).length - 2)
    }
    if text.hasSuffix("\n") || text.hasSuffix("\r") { return String(text.dropLast()) }
    return text
  }
}
