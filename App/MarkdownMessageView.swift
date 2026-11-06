import SwiftUI
import UIKit

struct MarkdownMessageView: View, Equatable {
  let source: String
  var body: some View {
    MarkdownBlockStack(nodes: MarkdownDocumentParser.parse(source))
    .contextMenu {
      Button(L10n.text("复制回答"), systemImage: "doc.on.doc") { UIPasteboard.general.string = source }
    }
  }
}

private struct MarkdownTableView: View {
  let table: MarkdownRichTable
  @ScaledMetric(relativeTo: .subheadline) private var scale: CGFloat = 1
  @State private var availableWidth: CGFloat = 0
  private var widths: [CGFloat] {
    table.headers.indices.map { column in
      let cells = [table.headers[column]] + table.rows.map { $0[column] }
      let widest = cells.map { value -> CGFloat in
        let text = String(value.characters) as NSString
        return text.size(withAttributes: [.font: UIFont.systemFont(ofSize: 15 * scale, weight: .medium)]).width + 24
      }.max() ?? 0
      return min(230 * scale, max(86 * scale, ceil(widest)))
    }
  }
  var body: some View {
    let widths = widths
    VStack(alignment: .leading, spacing: 6) {
      ScrollView(.horizontal) {
        VStack(spacing: 0) {
          row(table.headers, widths: widths, header: true, alternate: false)
          ForEach(table.rows.indices, id: \.self) { index in
            row(table.rows[index], widths: widths, header: false, alternate: index % 2 == 1)
          }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.13)))
        .padding(.bottom, 5)
      }
      .scrollIndicators(.visible)
      .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
      if widths.reduce(0, +) > availableWidth + 1, availableWidth > 0 {
        Label(L10n.text("左右滑动查看表格"), systemImage: "arrow.left.and.right")
          .font(.caption2).foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
  private func row(_ cells: [AttributedString], widths: [CGFloat], header: Bool, alternate: Bool) -> some View {
    HStack(alignment: .top, spacing: 0) {
      ForEach(cells.indices, id: \.self) { column in
        Text(markdownInlineStyle(cells[column], codeFont: .system(.subheadline, design: .monospaced)))
          .font(.subheadline).fontWeight(header ? .semibold : .regular)
          .multilineTextAlignment(textAlignment(column))
          .fixedSize(horizontal: false, vertical: true)
          .frame(width: max(1, widths[column] - 24), alignment: alignment(column))
          .padding(12)
          .textSelection(.enabled)
          .accessibilityLabel(accessibilityText(cells[column], column: column, header: header))
          .accessibilityAddTraits(header ? .isHeader : [])
      }
    }
    .background(header ? SoloStyle.accent.opacity(0.10) : alternate ? Color.primary.opacity(0.035) : SoloStyle.surface)
    .overlay(alignment: .bottom) { Color.primary.opacity(0.08).frame(height: 0.5) }
  }
  private func alignment(_ column: Int) -> Alignment {
    switch table.alignments[column] {
    case .leading: .leading
    case .center: .center
    case .trailing: .trailing
    }
  }
  private func textAlignment(_ column: Int) -> TextAlignment {
    switch table.alignments[column] {
    case .leading: .leading
    case .center: .center
    case .trailing: .trailing
    }
  }
  private func accessibilityText(_ cell: AttributedString, column: Int, header: Bool) -> String {
    let text = String(cell.characters)
    let title = String(table.headers[column].characters)
    return !header && !title.isEmpty ? title + ": " + text : text
  }

}

// Explicit monospace styling for inline code; semantic bold/italic/strike/link
// attributes from Foundation remain attached to the rest of the text.
private func markdownInlineStyle(_ source: AttributedString, codeFont: Font = .system(.body, design: .monospaced)) -> AttributedString {
  var styled = source
  for run in source.runs where run.inlinePresentationIntent?.contains(.code) == true {
    styled[run.range].font = codeFont
  }
  return styled
}

private struct MarkdownBlockStack: View {
  let nodes: [MarkdownRenderNode]
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      ForEach(nodes) { node in
        MarkdownBlockView(node: node)
          .padding(.top, headingSpacing(node))
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
  private func headingSpacing(_ node: MarkdownRenderNode) -> CGFloat {
    if case .header = node.kind, node.id != nodes.first?.id { return 6 }
    return 0
  }
}

private struct MarkdownBlockView: View {
  let node: MarkdownRenderNode
  var body: some View {
    switch node.kind {
    case .paragraph:
      Text(markdownInlineStyle(node.text)).lineSpacing(3).textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    case .header(let level):
      Text(markdownInlineStyle(node.text, codeFont: headingFont(level).monospaced())).font(headingFont(level)).fontWeight(.semibold)
        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityAddTraits(.isHeader)
    case .orderedList, .unorderedList:
      AnyView(MarkdownListView(node: node))
    case .blockQuote:
      AnyView(MarkdownBlockStack(nodes: node.children))
        .padding(.leading, 14).padding(.vertical, 6)
        .overlay(alignment: .leading) {
          RoundedRectangle(cornerRadius: 2).fill(SoloStyle.accent.opacity(0.55)).frame(width: 3)
        }
    case .codeBlock(let language):
      MarkdownCodeView(code: String(node.text.characters), language: language)
    case .thematicBreak:
      Divider().padding(.vertical, 6).accessibilityHidden(true)
    case .table:
      VStack(alignment: .leading, spacing: 14) {
        ForEach(node.tables.indices, id: \.self) { MarkdownTableView(table: node.tables[$0]) }
      }
    case .listItem, .tableHeaderRow, .tableRow, .tableCell:
      AnyView(MarkdownBlockStack(nodes: node.children))
    @unknown default:
      Text(node.text).textSelection(.enabled)
    }
  }
  private func headingFont(_ level: Int) -> Font {
    switch level {
    case 1: .title
    case 2: .title2
    case 3: .title3
    case 4: .headline
    case 5: .subheadline
    default: .footnote
    }
  }
}

private struct MarkdownListView: View {
  let node: MarkdownRenderNode
  @ScaledMetric(relativeTo: .body) private var markerUnit: CGFloat = 1
  private var ordered: Bool { node.kind == .orderedList }
  private var markerWidth: CGFloat {
    let digits = node.children.compactMap { item -> Int? in
      if case .listItem(let ordinal) = item.kind { return String(ordinal).count }; return nil
    }.max() ?? 1
    return (ordered ? max(24, CGFloat(digits) * 11 + 10) : 22) * markerUnit
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(node.children) { item in
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          marker(item).frame(width: markerWidth, alignment: ordered ? .trailing : .center)
          MarkdownBlockStack(nodes: item.children)
        }
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
  @ViewBuilder private func marker(_ item: MarkdownRenderNode) -> some View {
    if let checked = item.checked {
      Image(systemName: checked ? "checkmark.square.fill" : "square")
        .foregroundStyle(checked ? SoloStyle.accent : .secondary)
        .accessibilityLabel(checked ? L10n.text("已勾选") : L10n.text("未勾选"))
    } else if ordered, case .listItem(let ordinal) = item.kind {
      Text("\(ordinal).").monospacedDigit()
    } else { Text("•").accessibilityHidden(true) }
  }
}

private struct MarkdownCodeView: View {
  let code: String
  let language: String?
  @State private var copied = false
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 10) {
        Text(language?.isEmpty == false ? language! : L10n.text("代码"))
          .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
        Spacer(minLength: 8)
        Button {
          UIPasteboard.general.string = code
          copied = true
        } label: {
          Label(copied ? L10n.text("已复制") : L10n.text("复制代码"), systemImage: copied ? "checkmark" : "doc.on.doc")
            .font(.caption)
        }.buttonStyle(.plain).foregroundStyle(SoloStyle.accent)
      }.padding(.horizontal, 12).padding(.vertical, 10)
        .background(Color.primary.opacity(0.045))
      Divider()
      ScrollView(.horizontal) {
        Text(verbatim: code).font(.system(.subheadline, design: .monospaced))
          .fixedSize(horizontal: true, vertical: true).textSelection(.enabled)
          .padding(12)
      }.scrollIndicators(.visible)
    }
    .background(SoloStyle.surface, in: RoundedRectangle(cornerRadius: 12))
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.12)))
    .task(id: copied) {
      if copied {
        try? await Task.sleep(for: .seconds(2))
        if !Task.isCancelled { copied = false }
      }
    }
  }
}
