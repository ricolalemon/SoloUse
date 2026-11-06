import Foundation
private func check(_ value: Bool, _ message: String) throws {
  if !value { throw NSError(domain: "MarkdownDocumentTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
private func flatten(_ nodes: [MarkdownRenderNode]) -> [MarkdownRenderNode] {
  nodes.flatMap { [$0] + flatten($0.children) }
}
private func parse(_ source: String) -> [MarkdownRenderNode] { MarkdownDocumentParser.parse(source) }
@main struct MarkdownDocumentTests {
  static func main() throws {
    let source = #"""
    # Heading **bold**

    ## 二级标题

    Underlined heading
    ------------------

    ### Third
    #### Fourth
    ##### Fifth
    ###### Sixth

    Paragraph *emphasis*, **strong**, ~~deleted~~, `inline_code` and [link][target].
    Soft line break.  
    Hard line break.

    3. First item
       - Nested bullet
         - [x] Finished
       - [ ] Pending
    4. Second item

    > Quote
    >
    > - Quoted item
    >   1. Nested numbered item

    ---

    ```swift
      let literal = "# **not bold** | no table"

      print(literal)
    ```

    [target]: https://example.com/page
    """#
    let nodes = parse(source), flat = flatten(nodes)
    let levels = flat.compactMap { n -> Int? in if case .header(let level) = n.kind { return level }; return nil }
    try check(levels == [1,2,2,3,4,5,6], "Heading hierarchy or setext heading lost")
    try check(flat.contains { $0.kind == .thematicBreak }, "Divider lost")
    let body = flat.first { String($0.text.characters).contains("Paragraph") }!.text
    try check(body.runs.contains { $0.inlinePresentationIntent?.contains(.emphasized) == true }, "Emphasis lost")
    try check(body.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }, "Bold lost")
    try check(body.runs.contains { $0.inlinePresentationIntent?.contains(.strikethrough) == true }, "Strikethrough lost")
    try check(body.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true }, "Inline code lost")
    try check(body.runs.contains { $0.link?.absoluteString == "https://example.com/page" }, "Reference link did not resolve across blocks")
    try check(String(body.characters).contains("\nHard line break."), "Hard line break lost")
    print("PASS six heading levels, setext, dividers, rich inline styles, reference links and hard breaks")

    let ordered = nodes.first { $0.kind == .orderedList }!
    let ordinals = ordered.children.compactMap { n -> Int? in if case .listItem(let ordinal) = n.kind { return ordinal }; return nil }
    try check(ordinals == [3,4], "Ordered-list starting number changed")
    try check(ordered.children[0].children.contains { $0.kind == .unorderedList }, "Nested list flattened")
    try check(flat.filter { $0.checked != nil }.map(\.checked) == [true,false], "Task-list states incorrect")
    try check(flat.contains { $0.kind == .blockQuote && flatten($0.children).contains { $0.kind == .orderedList } }, "Nested list inside quote lost")
    for literal in [#"- \[x] escaped"#, "- `[x]` code", "- **[x]** strong", "- [[x]](https://example.com) link", "[x] ordinary paragraph"] {
      try check(flatten(parse(literal)).allSatisfy { $0.checked == nil }, "Literal checkbox became a task: \(literal)")
    }
    print("PASS hanging-list structure, numbering, nesting, quotes and literal-vs-task checkbox boundaries")

    let code = flat.first { if case .codeBlock = $0.kind { return true }; return false }!
    try check(String(code.text.characters) == "  let literal = \"# **not bold** | no table\"\n\n  print(literal)\n", "Code whitespace/content changed")
    try check(code.kind == .codeBlock(languageHint: "swift"), "Code language lost")
    try check(code.text.runs.allSatisfy { $0.inlinePresentationIntent == nil && $0.link == nil }, "Code interpreted as rich text")
    let indented = flatten(parse("    let x = 3\n\n    print(x)"))
    try check(indented.contains { if case .codeBlock = $0.kind { return String($0.text.characters).contains("let x = 3\n\nprint(x)") }; return false }, "Indented code lost")
    let openFence = flatten(parse("~~~python\n    value = '**literal**'"))
    try check(openFence.contains { $0.kind == .codeBlock(languageHint: "python") && String($0.text.characters).contains("    value = '**literal**'") }, "Open fence not rendered as code")
    try check(parse("```swift\n```").first?.kind == .codeBlock(languageHint: "swift"), "Empty code block disappeared")
    try check(flatten(parse("1. [x] Done")).contains { $0.checked == true }, "Ordered task item not recognized")
    print("PASS fenced/indented/open code blocks, language tags, whitespace and literal code content")

    let tableSource = """
    # Table

    | A | B |
    |---|--:|
    | **one** | [two][r] |
    | x | y | extra |
    | | |

    > | quoted | table |
    > |---|---|
    > | a | b |

    [r]: https://example.com
    """
    let tableNodes = flatten(parse(tableSource)).filter { !$0.tables.isEmpty }
    try check(tableNodes.count == 2, "Top-level or quoted table lost")
    let table = tableNodes[0].tables[0]
    try check(table.headers.count == 3 && table.rows.count == 3, "Existing extra/empty table cell preservation regressed")
    try check(String(table.rows[1][2].characters) == "extra", "Extra cell discarded")
    try check(table.rows[0][1].runs.contains { $0.link?.absoluteString == "https://example.com" }, "Table reference link lost")
    let adjacent = flatten(parse("|a|b|\n|-|-|\n|1|2|\n|c|d|\n|-|-|\n|3|4|"))
    try check(adjacent.flatMap(\.tables).count == 2, "Adjacent tables regressed")
    print("PASS table compatibility, empty/extra cells, reference links and quoted/adjacent tables")

    for end in source.indices {
      let prefix = String(source[..<end])
      let rendered = flatten(parse(prefix))
      try check(Set(rendered.map(\.id)).count == rendered.count, "Duplicate render identities during streaming")
      for table in rendered.flatMap(\.tables) {
        try check(table.headers.count == table.alignments.count && table.rows.allSatisfy { $0.count == table.headers.count }, "Partial table is not rectangular")
      }
    }
    let image = flatten(parse("![Image alt](https://example.com/image.png)"))
    try check(image.allSatisfy { $0.text.runs.allSatisfy { $0.imageURL == nil } }, "Remote image attachment leaked into text renderer")
    let plain = "普通消息🙂 without formatting"
    try check(String(parse(plain)[0].text.characters) == plain, "Plain content changed")
    print("PASS all streamed prefixes, unique IDs, rectangular partial tables, plain Unicode and no image loaders")
  }
}
