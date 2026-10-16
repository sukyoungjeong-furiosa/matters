import Foundation

@main struct EditingTests {
  static func main() {
    var count = 0
    func check(_ condition: @autoclosure () -> Bool, _ name: String) {
      precondition(condition(), name)
      count += 1
      print("PASS: " + name)
    }
    func edit(_ text: String, _ selection: NSRange, _ command: MarkdownCommand) -> MarkdownChange {
      MarkdownEditing.change(in: text, selection: selection, command: command)!
    }
    // Deliberate Hangul fixtures exercise UTF-16 selection offsets.
    let unicodeText = "\u{C55E} 😀 \u{D55C}\u{AE00} \u{B4A4}"
    let selected = (unicodeText as NSString).range(of: "\u{D55C}\u{AE00}")
    let bold = edit(unicodeText, selected, .bold)
    let boldText = bold.applied(to: unicodeText)
    check(
      boldText == "\u{C55E} 😀 **\u{D55C}\u{AE00}** \u{B4A4}",
      "Bold respects Unicode and emoji offsets")
    check(
      (boldText as NSString).substring(with: bold.selection) == "\u{D55C}\u{AE00}",
      "Formatted content stays selected")
    check(
      edit(boldText, bold.selection, .bold).applied(to: boldText) == unicodeText,
      "Repeated bold removes surrounding markers")
    let fullBold = "**\u{D55C}\u{AE00}**"
    check(
      edit(fullBold, NSRange(location: 0, length: (fullBold as NSString).length), .bold).applied(
        to: fullBold) == "\u{D55C}\u{AE00}", "Selected complete bold syntax can be removed")
    let italic = edit("**text**", NSRange(location: 2, length: 4), .italic)
    check(
      italic.applied(to: "**text**") == "***text***",
      "Italic can be added inside bold without stripping bold")
    let empty = edit("", NSRange(location: 0, length: 0), .bold)
    check(
      empty.applied(to: "") == "****" && empty.selection == NSRange(location: 2, length: 0),
      "Empty bold inserts markers with caret inside")
    check(
      edit("****", empty.selection, .bold).applied(to: "****") == "",
      "Empty marker pair toggles off")
    let code = "let value = 1\nprint(value)"
    let block = edit(code, NSRange(location: 0, length: (code as NSString).length), .codeBlock)
    let blockText = block.applied(to: code)
    check(blockText == "```\n" + code + "\n```", "Code block wraps selected lines")
    check(
      edit(blockText, block.selection, .codeBlock).applied(to: blockText) == code,
      "Code block toggles off without changing content")
    let lines = "first\nsecond\nthird\n"
    let second = (lines as NSString).range(of: "second")
    let middle = edit(lines, second, .codeBlock)
    check(
      middle.applied(to: lines) == "first\n```\nsecond\n```\nthird\n",
      "Code block preserves surrounding lines and line endings")
    let middleText = middle.applied(to: lines)
    check(
      edit(middleText, middle.selection, .codeBlock).applied(to: middleText) == lines,
      "Middle code block round trip preserves document exactly")
    let ticks = "literal ``` inside"
    check(
      edit(ticks, NSRange(location: 0, length: ticks.utf16.count), .codeBlock).replacement
        .hasPrefix("````\n"), "Fence length accommodates embedded backticks")
    let crlf = "abc\r\ndef\r\n"
    let windows = edit(crlf, NSRange(location: 0, length: 3), .codeBlock)
    let windowsText = windows.applied(to: crlf)
    check(
      windowsText == "```\r\nabc\r\n```\r\ndef\r\n",
      "Windows line endings and last content character preserved")
    check(
      edit(windowsText, windows.selection, .codeBlock).applied(to: windowsText) == crlf,
      "Windows code block round trip")
    let blank = edit("", NSRange(location: 0, length: 0), .codeBlock)
    check(
      blank.replacement == "```\n\n```" && blank.selection == NSRange(location: 4, length: 0),
      "Empty code block positions caret on blank code line")
    check(
      MarkdownEditing.change(in: "😀", selection: NSRange(location: 1, length: 1), command: .bold)
        == nil, "Invalid surrogate selection rejected")
    check(
      MarkdownEditing.change(in: "abc", selection: NSRange(location: 10, length: 0), command: .bold)
        == nil, "Out of bounds selection rejected")
    print("\(count) editing checks passed")
  }
}
