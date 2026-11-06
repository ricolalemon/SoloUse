import SafariServices
import SwiftUI
import UIKit

@MainActor final class SubscriptionModel: ObservableObject {
  static let shared = SubscriptionModel()
  @Published var busy = false
  @Published var signedIn = false
  @Published var code = ""
  @Published var status = L10n.text("登录后可在任务页操作手机")
  @Published var plan = ""
  private let client = SubscriptionClient()
  private var operation: Task<Void, Never>?

  init() { restore() }
  #if DEBUG
    init(interfacePreview signedIn: Bool) {
      self.signedIn = signedIn
      self.plan = signedIn ? "pro" : ""
      self.status = signedIn ? L10n.text("登录信息已保存在这台 iPhone") : L10n.text("登录后即可选择模型并开始任务")
    }
  #endif
  private func restore() {
    do {
      let tokens = try SubscriptionKeychain.load()
      signedIn = tokens != nil
      plan = tokens?.plan ?? ""
      if signedIn { status = L10n.text("已保存本机登录") }
    } catch { status = L10n.text("无法读取本机登录，请重试") }
  }

  private func record(_ fields: [String: Any]) {
    // Only explicitly selected non-secret metadata reaches the shared diagnostic log.
    var event = fields
    event["kind"] = "subscription_test"
    ProbeModel.shared.log(event)
  }

  private func begin(_ action: @escaping () async throws -> Void) {
    guard !busy, !PhoneAgentModel.shared.busy, !ModelSelection.shared.busy,
      !PhonePreparationModel.shared.busy else { return }
    busy = true
    UIApplication.shared.isIdleTimerDisabled = true
    operation = Task {
      defer {
        busy = false
        operation = nil
        code = ""
        UIApplication.shared.isIdleTimerDisabled = false
      }
      do { try await action() } catch is CancellationError {
        status = L10n.text("已停止")
        record(["stage": "cancelled"])
      } catch let error as SubscriptionFailure {
        status = error.localizedDescription
        record(["stage": "failed", "message": error.localizedDescription])
      } catch let error as URLError {
        status = error.code == .cancelled ? L10n.text("已停止") : L10n.text("网络请求失败（\(error.code.rawValue)）")
        record(["stage": "network_failed", "code": error.code.rawValue])
      } catch {
        status = L10n.text("响应解析失败，请保留当前状态以便检查")
        record(["stage": "decode_failed"])
      }
    }
  }

  func login() {
    begin {
      self.status = L10n.text("正在向 OpenAI 申请设备码…")
      self.record(["stage": "login_started", "transport": "iphone_https"])
      let tokens = try await self.client.authorize { code in
        self.code = code
        self.status = L10n.text("请打开 OpenAI 网页，输入上面的代码；授权后返回此页")
        self.record(["stage": "device_code_ready"])
      }
      ModelSelection.shared.clearCatalog()
      self.signedIn = true
      self.plan = tokens.plan
      self.status = L10n.text("登录完成，凭据已保存到这台 iPhone")
      self.record(["stage": "login_completed", "plan": tokens.plan])
    }
  }

  func stop() { operation?.cancel() }
  func forget() {
    guard !busy, !PhoneAgentModel.shared.busy, !ModelSelection.shared.busy,
      !PhonePreparationModel.shared.busy else { return }
    do {
      try SubscriptionKeychain.delete()
      ModelSelection.shared.clearCatalog()
      signedIn = false
      plan = ""
      code = ""
      status = L10n.text("本机登录已清除")
      record(["stage": "local_credentials_removed"])
    } catch { status = L10n.text("本机登录清除失败") }
  }
}

private struct AuthorizationBrowser: UIViewControllerRepresentable {
  func makeUIViewController(context: Context) -> SFSafariViewController {
    SFSafariViewController(url: SubscriptionClient.verificationURL)
  }
  func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

struct SubscriptionView: View {
  @ObservedObject var model: SubscriptionModel
  @ObservedObject var probe: ProbeModel
  @ObservedObject private var agent = PhoneAgentModel.shared
  @ObservedObject private var selection = ModelSelection.shared
  @ObservedObject private var preparation = PhonePreparationModel.shared
  @State private var showBrowser = false
  @State private var confirmSignOut = false
  private var locked: Bool { model.busy || probe.busy || agent.busy || selection.busy || preparation.busy }
  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("账号")).font(.title.bold())
            Text(L10n.text("使用 ChatGPT / Codex 订阅。")).font(.callout).foregroundStyle(.secondary)
          }.padding(.top, 8)
          SoloCard {
            VStack(alignment: .leading, spacing: 18) {
              HStack(spacing: 13) {
                Image(systemName: "person.crop.circle.fill").font(.system(size: 38))
                  .foregroundStyle(SoloStyle.accent)
                VStack(alignment: .leading, spacing: 5) {
                  Text("ChatGPT / Codex").font(.headline)
                  Text(
                    model.signedIn
                      ? (model.plan.isEmpty ? L10n.text("订阅账号") : model.plan.uppercased() + L10n.text(" 订阅")) : L10n.text("连接你的账号")
                  )
                  .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                StateBadge(
                  text: model.signedIn ? L10n.text("已登录") : L10n.text("未登录"),
                  color: model.signedIn ? SoloStyle.accent : .secondary)
              }
              if !model.signedIn && !model.busy {
                Button {
                  model.login()
                } label: {
                  Label(L10n.text("登录 ChatGPT"), systemImage: "arrow.right")
                    .frame(maxWidth: .infinity).padding(.vertical, 5)
                }.buttonStyle(.borderedProminent).controlSize(.large).disabled(locked)
              }
              if !model.code.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                  Text(L10n.text("在 OpenAI 网页输入此代码")).font(.caption).foregroundStyle(.secondary)
                  Text(model.code).font(.system(.largeTitle, design: .monospaced, weight: .bold))
                    .textSelection(.enabled)
                  Button(L10n.text("打开授权网页"), systemImage: "arrow.up.right.square") { showBrowser = true }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                  Button(L10n.text("复制代码"), systemImage: "doc.on.doc") {
                    UIPasteboard.general.setItems(
                      [[UIPasteboard.typeAutomatic: model.code]],
                      options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(900)])
                  }.buttonStyle(.bordered)
                  Text(L10n.text("网页提示未启用设备码登录时，请先在 ChatGPT 安全设置中开启。授权后返回这里即可。"))
                    .font(.caption).foregroundStyle(.secondary)
                }
              }
              if model.busy {
                HStack(spacing: 10) {
                  ProgressView().controlSize(.small)
                  Text(model.code.isEmpty ? L10n.text("正在连接…") : L10n.text("等待网页授权…")).font(.subheadline)
                  Spacer()
                  Button(L10n.text("取消")) { model.stop() }.font(.subheadline)
                }
              }
              Text(L10n.text(model.status)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
          }
          SoloCard {
            VStack(alignment: .leading, spacing: 16) {
              accountInfo(L10n.text("登录方式"), detail: L10n.text("在 OpenAI 网页授权。"), icon: "lock.shield")
              Divider()
              accountInfo(L10n.text("登录信息"), detail: L10n.text("保存在本机钥匙串。"), icon: "key.horizontal")
              Divider()
              accountInfo(L10n.text("屏幕内容"), detail: L10n.text("任务所需截图会发送给你选择的云端模型。"), icon: "photo")
            }
          }
          if model.signedIn {
            Button(L10n.text("退出本机登录"), role: .destructive) { confirmSignOut = true }
              .font(.subheadline).disabled(locked).frame(maxWidth: .infinity).padding(.vertical, 8)
          }
          VStack(spacing: 6) {
            Text(
              "SoloUse · \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? L10n.text("实验版"))"
            )
            .font(.caption.weight(.medium))
            Text(L10n.text("实验版")).font(.caption2)
          }.foregroundStyle(.secondary).frame(maxWidth: .infinity)
        }.padding(20)
      }.background(SoloStyle.canvas)
        .navigationTitle(L10n.text("账号")).navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showBrowser) { AuthorizationBrowser().ignoresSafeArea() }
        .onChange(of: model.signedIn) { _, signedIn in if signedIn { showBrowser = false } }
        .confirmationDialog(L10n.text("退出本机登录？"), isPresented: $confirmSignOut, titleVisibility: .visible) {
          Button(L10n.text("退出登录"), role: .destructive) { model.forget() }
        } message: {
          Text(L10n.text("这会清除手机上保存的登录信息，不会撤销 OpenAI 服务端授权。"))
        }
    }
  }
  private func accountInfo(_ title: String, detail: String, icon: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: icon).font(.system(size: 17)).foregroundStyle(SoloStyle.accent).frame(
        width: 24)
      VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.subheadline.weight(.medium))
        Text(detail).font(.caption).foregroundStyle(.secondary)
      }
    }
  }
}
