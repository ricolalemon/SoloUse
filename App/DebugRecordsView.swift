import SwiftUI
import UIKit

struct DebugRecordsView: View {
  @ObservedObject private var diagnostics = TaskDiagnostics.shared
  @ObservedObject private var agent = PhoneAgentModel.shared
  @State private var records: [DebugTraceSummary] = []
  @State private var exporting = false
  @State private var exported: ExportedFile?
  @State private var error = ""
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    NavigationStack {
      List {
        Section {
          Toggle(L10n.text("保留观察截图"), isOn: $diagnostics.saveScreenshots).disabled(agent.busy)
          Toggle(L10n.text("记录任务、回复和输入原文"), isOn: $diagnostics.saveVisibleText).disabled(agent.busy)
        } header: {
          Text(L10n.text("下次任务的记录方式"))
        } footer: {
          Text(
            L10n.text("默认记录坐标、耗时、错误和暂停来源；输入文字只记长度。调试记录可能包含私人内容，保存在本机且不会自动上传。执行任务时，模型仍会接收所需的屏幕和输入。SoloUse 登录凭据、配对文件和模型内部推理不进入调试包。")
          )
        }
        Section(L10n.text("最近 5 次任务")) {
          if records.isEmpty { Text(L10n.text("从这个版本开始，启动任务后会自动建立记录。")).foregroundStyle(.secondary) }
          ForEach(records) { record in
            VStack(alignment: .leading, spacing: 8) {
              Text(
                record.manifest.startedAt, format: .dateTime.month().day().hour().minute().second()
              ).font(.headline)
              Text(
                "\(record.manifest.version) · \(record.manifest.kind) · \(record.manifest.outcome)"
              )
              .font(.caption).foregroundStyle(.secondary)
              Text(L10n.text("\(record.manifest.events) 条事件 · \(record.manifest.savedFrames) 张截图"))
                .font(.caption).foregroundStyle(.secondary)
              if record.manifest.droppedEvents + record.manifest.skippedFrames
                + record.manifest.writeFailures > 0
              {
                Text(L10n.text("部分记录未保存；原因和计数包含在调试包中。")).font(.caption).foregroundStyle(.orange)
              }
              HStack {
                Button(L10n.text("导出调试包"), systemImage: "square.and.arrow.up") { export(record.id) }
                  .buttonStyle(.bordered).disabled(exporting)
                Spacer()
                Button(role: .destructive) {
                  remove(record.id)
                } label: {
                  Image(systemName: "trash")
                }
                .buttonStyle(.borderless).disabled(agent.busy || exporting)
              }
            }.padding(.vertical, 4)
          }
        }
        Section {
          Text(L10n.text("每次最多保留 24 张观察截图、约 24 MB 日志与图片。图片是模型实际收到的版本，事件可按 frame_id 和调用编号关联。"))
            .font(.caption).foregroundStyle(.secondary)
          if !diagnostics.storageError.isEmpty {
            Text(L10n.text(diagnostics.storageError)).foregroundStyle(.orange)
          }
          if !error.isEmpty { Text(L10n.text(error)).foregroundStyle(.orange) }
          if exporting { ProgressView(L10n.text("正在生成调试包…")) }
        }
      }
      .navigationTitle(L10n.text("调试记录")).navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("完成")) { dismiss() } } }
      .task { records = await diagnostics.summaries() }
      .refreshable { records = await diagnostics.summaries() }
      .sheet(item: $exported) { file in DebugShareSheet(url: file.url) }
    }
  }
  private func export(_ id: UUID) {
    exporting = true
    error = ""
    Task {
      defer { exporting = false }
      do { exported = ExportedFile(url: try await diagnostics.export(id)) } catch {
        self.error = error.localizedDescription
      }
      records = await diagnostics.summaries()
    }
  }
  private func remove(_ id: UUID) {
    Task {
      do {
        try await diagnostics.delete(id)
        records = await diagnostics.summaries()
      } catch { self.error = error.localizedDescription }
    }
  }
}
private struct ExportedFile: Identifiable {
  let id = UUID()
  let url: URL
}
private struct DebugShareSheet: UIViewControllerRepresentable {
  let url: URL
  func makeUIViewController(context: Context) -> UIActivityViewController {
    UIActivityViewController(activityItems: [url], applicationActivities: nil)
  }
  func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
