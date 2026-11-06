#if DEBUG
import SwiftUI

struct MarkdownPreview: View {
  var variant: Int = 0
  var body: some View {
    NavigationStack {
      ScrollView {
        MarkdownMessageView(source: variant == 0 ? Self.sample : Self.richSample(variant)).equatable().padding(16)
      }
      .background(SoloStyle.canvas)
      .navigationTitle(L10n.text("回答预览")).navigationBarTitleDisplayMode(.inline)
    }
  }
  static var sample: String {
    if L10n.language == .chinese {
      return #"""
      这里有 **4 个示例选项**，评分为 5 分制。

      | 店名 | 评分 / 评价数 | 距离 | 今日营业信息 |
      |---|---:|---:|---|
      | **Example Coffee House** | **4.8** / 74 条 | 约 1.6 公里 | **08:00–23:00**；查询时尚未开门 |
      | River Coffee Company | 4.4 / 864 条 | 约 2.7 公里 | 已营业，**22:00** 关门 |
      | 山间咖啡🙂 | 4.3 / 484 条 | 约 1.0 公里 | 已营业，**14:00** 关门 |
      | Garden Cup | 4.2 / 439 条 | 约 1.3 公里 | 已营业，**22:00** 关门 |

      **怎么选：**
      - 评分优先：Example Coffee House。
      - 距离优先：山间咖啡。

      | 功能 | 状态 |
      | :--- | :---: |
      | **加粗**与[链接](https://example.com) | 可用 |
      | `a\|b` | 第一行<br>第二行 |
      """#
    }
    return #"""
    Here are **4 example options**, rated out of five.

    | Café | Rating / reviews | Distance | Today's hours |
    |---|---:|---:|---|
    | **Example Coffee House** | **4.8** / 74 | About 1.6 km | **08:00–23:00**; not open yet |
    | River Coffee Company | 4.4 / 864 | About 2.7 km | Open; closes at **22:00** |
    | Mountain Café🙂 | 4.3 / 484 | About 1.0 km | Open; closes at **14:00** |
    | Garden Cup | 4.2 / 439 | About 1.3 km | Open; closes at **22:00** |

    **Choosing an option:**
    - Best rating: Example Coffee House.
    - Nearest: Mountain Café.

    | Feature | Status |
    | :--- | :---: |
    | **Bold** and [links](https://example.com) | Available |
    | `a\|b` | First line<br>Second line |
    """#
  }
  static func richSample(_ variant: Int) -> String {
    let chinese = L10n.language == .chinese
    if variant == 2 || variant == 3 {
      let intro = chinese ? "## 代码示例\n代码保留缩进和空行，长行可以左右滑动。\n\n" : "## Code example\nIndentation and blank lines are preserved. Swipe sideways for long lines.\n\n"
      let code = #"""
      ```swift
      func greeting(_ name: String) -> String {
          // Literal Markdown: # **text** | [x]
          return "Hello, \(name)"
      }

      let message = greeting("SoloUse")
      let longLine = "This deliberately long line keeps every character and its indentation while you scroll horizontally to the end."
      print(message)
      """#
      return intro + code + (variant == 3 ? "" : "\n```\n\n" + (chinese ? "行内代码：`greeting(\"SoloUse\")`，也支持 **加粗**、*斜体*和 ~~删除线~~。" : "Inline code: `greeting(\"SoloUse\")`, plus **bold**, *italic*, and ~~strikethrough~~."))
    }
    if variant == 4 {
      return chinese ? #"""
      ## 引用与嵌套内容

      > 这是一段 **引用**。
      >
      > ### 引用内的小标题
      > 1. 第一项
      >    - 子项目
      >    - [x] 已完成的示例
      > 2. 第二项
      >
      > | 项目 | 状态 |
      > |---|---|
      > | **嵌套表格** | 正常显示 |
      >
      > ```text
      >     code inside a quote
      >     # not a heading
      > ```

      ---

      [参考链接][reference]与普通段落。

      [reference]: https://example.com
      """# : #"""
      ## Quotes and nested content

      > This is a **quote**.
      >
      > ### Heading inside a quote
      > 1. First item
      >    - Nested bullet
      >    - [x] Completed example
      > 2. Second item
      >
      > | Item | Status |
      > |---|---|
      > | **Nested table** | Displayed |
      >
      > ```text
      >     code inside a quote
      >     # not a heading
      > ```

      ---

      A [reference link][reference] and a paragraph.

      [reference]: https://example.com
      """#
    }
    return chinese ? #"""
    # 标题与列表

    这段文字包含 **加粗**、*斜体*、~~删除线~~ 和 `行内代码`。

    ## 按顺序完成

    3. 从第三项开始编号，长句会自动换行，并与正文对齐。
       - 第一层子项目
         - 第二层子项目
       - 返回第一层
    4. 下一项保持连续编号。

    ### 任务清单

    - [x] 已完成的示例
    - [ ] 尚未完成的示例
    - `[x]` 出现在代码里时保持原文

    ---

    #### 第四级标题
    普通段落。

    ##### 第五级标题
    普通段落。

    ###### 第六级标题
    普通段落。
    """# : #"""
    # Headings and lists

    This paragraph includes **bold**, *italic*, ~~strikethrough~~, and `inline code`.

    ## Follow the steps

    3. Start at three. Long items wrap and align with the text instead of the number.
       - First nested item
         - Second nesting level
       - Back to the first level
    4. The next item keeps its numbering.

    ### Task list

    - [x] Completed example
    - [ ] Pending example
    - `[x]` remains literal inside code

    ---

    #### Fourth-level heading
    A normal paragraph.

    ##### Fifth-level heading
    A normal paragraph.

    ###### Sixth-level heading
    A normal paragraph.
    """#
  }

}
#endif
