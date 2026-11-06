import Foundation

// A display-only extension to the existing inline Markdown renderer. Source
// messages remain untouched. Fences/indented code never become tables.
struct MarkdownTable: Equatable {
  enum Alignment: Equatable { case leading, center, trailing }
  var headers: [String]
  var alignments: [Alignment]
  var rows: [[String]]
}
struct MarkdownMessageBlock: Equatable, Identifiable {
  enum Content: Equatable { case text(String), table(MarkdownTable) }
  let id: Int // Starting line stays stable as the streamed message grows.
  let content: Content
}

enum MarkdownTableParser {
  private struct Row { let cells: [String]; let hasPipe: Bool }
  private struct Fence { let marker: Character; let count: Int }

  static func parse(_ source: String) -> [MarkdownMessageBlock] {
    let lines = source.replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
    var blocks: [MarkdownMessageBlock] = [], index = 0, textStart = 0
    var fence: Fence?
    func flushText(until end: Int) {
      guard end > textStart else { return }
      let text = lines[textStart..<end].joined(separator: "\n")
      if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        blocks.append(.init(id: textStart, content: .text(text)))
      }
    }
    while index < lines.count {
      if let active = fence {
        if closesFence(lines[index], active) { fence = nil }
        index += 1; continue
      }
      if let opened = openingFence(lines[index]) { fence = opened; index += 1; continue }
      guard index + 1 < lines.count,
        let table = header(lines[index], delimiter: lines[index + 1]) else {
        index += 1; continue
      }
      flushText(until: index)
      let start = index
      var value = table
      index += 2
      while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).isEmpty,
        !startsBlock(lines[index]), !indentedCode(lines[index]) {
        // An adjacent explicit header begins a new table.
        if index + 1 < lines.count, header(lines[index], delimiter: lines[index + 1]) != nil { break }
        value.rows.append(splitRow(lines[index]).cells)
        index += 1
      }
      // Keep excess cells visible instead of silently discarding model content.
      let columns = max(value.headers.count, value.rows.map(\.count).max() ?? 0)
      value.headers += Array(repeating: "", count: columns - value.headers.count)
      value.alignments += Array(repeating: .leading, count: columns - value.alignments.count)
      value.rows = value.rows.map { $0 + Array(repeating: "", count: columns - $0.count) }
      blocks.append(.init(id: start, content: .table(value)))
      textStart = index
    }
    flushText(until: lines.count)
    // Preserve the original source exactly when no table was recognized.
    if !blocks.contains(where: { if case .table = $0.content { return true }; return false }) {
      return [.init(id: 0, content: .text(source))]
    }
    return blocks
  }

  private static func header(_ line: String, delimiter: String) -> MarkdownTable? {
    guard !indentedCode(line), !indentedCode(delimiter), !startsBlock(line) else { return nil }
    let head = splitRow(line), rule = splitRow(delimiter)
    guard head.hasPipe || rule.hasPipe, !head.cells.isEmpty, head.cells.count == rule.cells.count else { return nil }
    var alignments: [MarkdownTable.Alignment] = []
    for cell in rule.cells {
      var body = cell[...]
      let left = body.first == ":", right = body.last == ":"
      if left { body = body.dropFirst() }
      if right, !body.isEmpty { body = body.dropLast() }
      guard !body.isEmpty, body.allSatisfy({ $0 == "-" }) else { return nil }
      alignments.append(left && right ? .center : right ? .trailing : .leading)
    }
    return .init(headers: head.cells, alignments: alignments, rows: [])
  }
  private static func splitRow(_ source: String) -> Row {
    let characters = Array(source.trimmingCharacters(in: .whitespaces))
    var cells: [String] = [], cell = "", index = 0, hasPipe = false
    while index < characters.count {
      let char = characters[index]
      if char == "\\", index + 1 < characters.count {
        let next = characters[index + 1]
        // GFM requires escaped pipes even inside code spans. Remove that one
        // escape before inline parsing; preserve all other Markdown escapes.
        if next == "|" { cell.append("|") }
        else { cell.append(char); cell.append(next) }
        index += 2; continue
      }
      if char == "|" {
        hasPipe = true; cells.append(cell.trimmingCharacters(in: .whitespaces)); cell = ""
      } else { cell.append(char) }
      index += 1
    }
    cells.append(cell.trimmingCharacters(in: .whitespaces))
    if characters.first == "|", !cells.isEmpty { cells.removeFirst() }
    // An empty final cell signals an unescaped trailing delimiter.
    if hasPipe, characters.last == "|", cells.last == "", !cells.isEmpty { cells.removeLast() }
    return Row(cells: cells, hasPipe: hasPipe)
  }
  private static func indentedCode(_ line: String) -> Bool {
    var columns = 0
    for char in line {
      if char == " " { columns += 1 }
      else if char == "\t" { columns += 4 - columns % 4 }
      else { break }
      if columns >= 4 { return true }
    }
    return false
  }
  private static func openingFence(_ line: String) -> Fence? {
    guard !indentedCode(line) else { return nil }
    let value = line.drop(while: { $0 == " " })
    guard let first = value.first, first == "`" || first == "~" else { return nil }
    let count = value.prefix(while: { $0 == first }).count
    guard count >= 3 else { return nil }
    if first == "`", value.dropFirst(count).contains("`") { return nil }
    return Fence(marker: first, count: count)
  }
  private static func closesFence(_ line: String, _ fence: Fence) -> Bool {
    guard !indentedCode(line) else { return false }
    let value = line.trimmingCharacters(in: .whitespaces)
    let count = value.prefix(while: { $0 == fence.marker }).count
    return count >= fence.count && value.dropFirst(count).trimmingCharacters(in: .whitespaces).isEmpty
  }
  private static func startsBlock(_ line: String) -> Bool {
    let value = line.trimmingCharacters(in: .whitespaces)
    if openingFence(line) != nil || value.hasPrefix(">") || value.hasPrefix("<!--") { return true }
    if value.hasPrefix("#") {
      let count = value.prefix(while: { $0 == "#" }).count
      if count <= 6, value.count == count || value.dropFirst(count).first?.isWhitespace == true { return true }
    }
    if ["- ", "* ", "+ "].contains(where: value.hasPrefix) { return true }
    let digits = value.prefix(while: { $0.isASCII && $0.isNumber })
    if !digits.isEmpty, digits.count <= 9 {
      let suffix = value.dropFirst(digits.count)
      if suffix.hasPrefix(". ") || suffix.hasPrefix(") ") { return true }
    }
    for marker: Character in ["-", "*", "_"] {
      let compact = value.filter { !$0.isWhitespace }
      if compact.count >= 3, compact.allSatisfy({ $0 == marker }) { return true }
    }
    return false
  }
}
