import Foundation

struct MarkdownRichTable: Equatable {
  var headers: [AttributedString]
  var alignments: [MarkdownTable.Alignment]
  var rows: [[AttributedString]]
}
struct MarkdownRenderNode: Equatable, Identifiable {
  let id: Int
  let kind: PresentationIntent.Kind
  var text: AttributedString
  var children: [MarkdownRenderNode]
  var checked: Bool?
  var tables: [MarkdownRichTable] = []
}

// Foundation supplies CommonMark block structure and inline attributes. This
// adapter only turns presentation intents into a render tree; it never alters
// the saved/model message or evaluates code, HTML, or image URLs.
enum MarkdownDocumentParser {
  private final class Builder {
    let id: Int
    let kind: PresentationIntent.Kind
    var text = AttributedString()
    var children: [Builder] = []
    var firstLine: Int?
    var firstColumn: Int?
    var lastLine: Int?
    init(id: Int, kind: PresentationIntent.Kind) { self.id = id; self.kind = kind }
    func observe(_ position: AttributedString.MarkdownSourcePosition?) {
      guard let position else { return }
      if firstLine == nil { firstLine = position.startLine; firstColumn = position.startColumn }
      lastLine = max(lastLine ?? 0, position.endLine)
    }
  }
  static func parse(_ source: String) -> [MarkdownRenderNode] {
    guard !source.isEmpty else { return [] }
    let normalized = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    guard let attributed = try? AttributedString(markdown: normalized, options: .init(
      interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible,
      appliesSourcePositionAttributes: true)) else {
      return [.init(id: 0, kind: .paragraph, text: AttributedString(source), children: [])]
    }
    let sourceLines = normalized.components(separatedBy: "\n")
    let root = Builder(id: -1, kind: .paragraph)
    var indexed: [Int: Builder] = [:]
    for run in attributed.runs {
      var parent = root
      for intent in (run.presentationIntent?.components ?? []).reversed() {
        let node: Builder
        if let previous = indexed[intent.identity] { node = previous }
        else {
          node = Builder(id: intent.identity, kind: intent.kind)
          indexed[intent.identity] = node
          parent.children.append(node)
        }
        node.observe(run.markdownSourcePosition)
        parent = node
      }
      var text = AttributedString(attributed[run.range])
      text.presentationIntent = nil
      text.markdownSourcePosition = nil
      text.imageURL = nil // Text-only image alt text; no network attachment loader.
      if parent === root {
        let node = Builder(id: -2 - root.children.count, kind: .paragraph)
        node.text = text; root.children.append(node)
      } else { parent.text += text }
    }
    let legacyTables: [(line: Int, table: MarkdownTable)] = normalized.contains("|")
      ? MarkdownTableParser.parse(normalized).compactMap {
        if case .table(let table) = $0.content { return ($0.id + 1, table) }; return nil
      } : []
    func freeze(_ builder: Builder, inList: Bool = false) -> MarkdownRenderNode {
      var node = MarkdownRenderNode(id: builder.id, kind: builder.kind, text: builder.text,
        children: builder.children.map { freeze($0, inList: builder.kind == .unorderedList || builder.kind == .orderedList) })
      if case .listItem = node.kind, inList, !node.children.isEmpty,
        node.children[0].kind == .paragraph,
        let line = builder.children.first?.firstLine, let column = builder.children.first?.firstColumn,
        sourceLines.indices.contains(line - 1) {
        let raw = String(decoding: sourceLines[line - 1].utf8.dropFirst(max(0, column - 1)), as: UTF8.self)
        let prefix = String(decoding: sourceLines[line - 1].utf8.prefix(max(0, column - 1)), as: UTF8.self)
        let followsMarker = prefix.range(of: #"(^|[\s>])(?:[-+*]|[0-9]{1,9}[.)])[ \t]+$"#, options: .regularExpression) != nil
        let text = String(node.children[0].text.characters)
        // Only literal task markers at the start of a list item count. Escaped
        // markers, inline code and paragraph text remain literal.
        if followsMarker, let marker = ["[ ]", "[x]", "[X]"].first(where: { raw.hasPrefix($0) && text.hasPrefix($0) }),
          text.count == 3 || text.dropFirst(3).first?.isWhitespace == true {
          node.checked = marker != "[ ]"
          let end = node.children[0].text.characters.index(node.children[0].text.startIndex,
            offsetBy: text.count > 3 ? 4 : 3)
          node.children[0].text.removeSubrange(node.children[0].text.startIndex..<end)
        }
      }
      if case .table(let columns) = node.kind {
        let matching = legacyTables.filter {
          $0.line >= (builder.firstLine ?? Int.max) && $0.line <= (builder.lastLine ?? -1)
        }
        if matching.count > 1 {
          // The prior renderer supports adjacent explicit headers without a
          // blank line. Preserve those tables instead of dropping later data.
          node.tables = matching.map { richTable($0.table) }
        } else {
          node.tables = [richTable(node, columns: columns, original: matching.first?.table)]
        }
      }
      return node
    }
    if root.children.isEmpty, let emptyCode = emptyFence(sourceLines) { return [emptyCode] }
    return root.children.map { freeze($0) }
  }

  private static func emptyFence(_ lines: [String]) -> MarkdownRenderNode? {
    let nonempty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    guard let first = nonempty.first, first.prefix(while: { $0 == " " }).count <= 3 else { return nil }
    let line = first.trimmingCharacters(in: .whitespaces)
    guard let marker = line.first, marker == "`" || marker == "~" else { return nil }
    let count = line.prefix(while: { $0 == marker }).count
    let hint = String(line.dropFirst(count)).trimmingCharacters(in: .whitespaces)
    guard count >= 3, !(marker == "`" && hint.contains("`")), nonempty.count <= 2 else { return nil }
    if nonempty.count == 2 {
      let closing = nonempty[1].trimmingCharacters(in: .whitespaces)
      guard closing.count >= count, closing.allSatisfy({ $0 == marker }) else { return nil }
    }
    return .init(id: 1, kind: .codeBlock(languageHint: hint.isEmpty ? nil : hint), text: AttributedString(), children: [])
  }

  static func inline(_ source: String) -> AttributedString {
    let value = source.replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: "\n", options: .regularExpression)
    var result = (try? AttributedString(markdown: value,
      options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(value)
    result.imageURL = nil
    return result
  }
  private static func richTable(_ original: MarkdownTable) -> MarkdownRichTable {
    .init(headers: original.headers.map(inline), alignments: original.alignments,
      rows: original.rows.map { $0.map(inline) })
  }
  private static func richTable(_ node: MarkdownRenderNode, columns: [PresentationIntent.TableColumn], original: MarkdownTable?) -> MarkdownRichTable {
    let count = max(columns.count, original?.headers.count ?? 0)
    let rowCount = max(original?.rows.count ?? 0, node.children.compactMap { child -> Int? in
      if case .tableRow(let index) = child.kind { return index }; return nil
    }.max() ?? 0)
    var result = original.map(richTable) ?? .init(
      headers: Array(repeating: AttributedString(), count: count),
      alignments: columns.map { $0.alignment == .right ? .trailing : $0.alignment == .center ? .center : .leading },
      rows: Array(repeating: Array(repeating: AttributedString(), count: count), count: rowCount))
    for row in node.children {
      let rowIndex: Int?
      if case .tableHeaderRow = row.kind { rowIndex = nil }
      else if case .tableRow(let index) = row.kind { rowIndex = index - 1 }
      else { continue }
      for cell in row.children {
        guard case .tableCell(let column) = cell.kind, column < count else { continue }
        let originalText = rowIndex.flatMap { original?.rows.indices.contains($0) == true ? original?.rows[$0][column] : nil }
          ?? (rowIndex == nil ? original?.headers[column] : nil)
        // Preserve existing explicit cell line-break handling. Other native
        // attributes keep resolved reference links and nested inline styles.
        let value = originalText?.range(of: #"(?i)<br\s*/?>"#, options: .regularExpression) != nil
          ? inline(originalText!) : cell.text
        if let rowIndex, result.rows.indices.contains(rowIndex) { result.rows[rowIndex][column] = value }
        else if rowIndex == nil { result.headers[column] = value }
      }
    }
    return result
  }
}
