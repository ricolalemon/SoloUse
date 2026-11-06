#if DEBUG
  import SwiftUI
  import UIKit

  // Explicit preview launch only. Fixtures never start a phone session, log in,
  // request a model, or save task/selection data. All preview interaction is disabled.
  @MainActor enum InterfaceSnapshotSuite {
    static func run() async {
      for _ in 0..<30 {
        if UIApplication.shared.applicationState == .active { break }
        try? await Task.sleep(for: .milliseconds(100))
      }
      guard UIApplication.shared.applicationState == .active,
        !PhoneAgentModel.shared.busy, !ProbeModel.shared.busy, !SubscriptionModel.shared.busy,
        let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
          .first(where: { $0.activationState == .foregroundActive }),
        let previous = scene.windows.first(where: { $0.isKeyWindow })
      else { return }
      let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(
          "ui-preview-"
            + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
              ?? "dev"),
          isDirectory: true)
      do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      } catch { return }
      let animationsEnabled = UIView.areAnimationsEnabled
      let idleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
      UIView.setAnimationsEnabled(false)
      UIApplication.shared.isIdleTimerDisabled = true
      defer {
        UIApplication.shared.isIdleTimerDisabled = idleTimerDisabled
        UIView.setAnimationsEnabled(animationsEnabled)
        previous.makeKeyAndVisible()
      }
      let originalLanguage = UserDefaults.standard.string(forKey: AppLanguage.defaultsKey)
      defer {
        if let originalLanguage { UserDefaults.standard.set(originalLanguage, forKey: AppLanguage.defaultsKey) }
        else { UserDefaults.standard.removeObject(forKey: AppLanguage.defaultsKey) }
      }
      let bilingual = ProcessInfo.processInfo.arguments.contains("--solouse-bilingual-snapshots")
      let languages = bilingual ? ["en", "zh-Hans"] : [L10n.language.rawValue]
      let richMarkdown = ProcessInfo.processInfo.arguments.contains("--solouse-rich-markdown-snapshots")
      let markdownOnly = richMarkdown || ProcessInfo.processInfo.arguments.contains("--solouse-markdown-snapshots")
      var tableScrollChecks: [[String: Any]] = []
      var files: [String] = []
      for language in languages {
      UserDefaults.standard.set(language, forKey: AppLanguage.defaultsKey)
      let states: [(String, TaskPhase, Int, Bool, Bool, Bool)] = markdownOnly ? [
        ("markdown", .idle, 7, true, false, false),
        ("markdown-right", .idle, 7, true, false, false),
        ("markdown-dark", .idle, 7, true, true, false),
        ("markdown-large", .idle, 7, true, false, true),
        ("markdown-narrow", .idle, 7, true, false, false),
      ] + (richMarkdown ? [
        ("blocks", .idle, 8, true, false, false),
        ("blocks-dark", .idle, 8, true, true, false),
        ("blocks-narrow", .idle, 8, true, false, false),
        ("blocks-large", .idle, 8, true, false, true),
        ("code", .idle, 9, true, false, false),
        ("code-right", .idle, 9, true, false, false),
        ("code-dark", .idle, 9, true, true, false),
        ("code-open", .idle, 10, true, false, false),
        ("nested", .idle, 11, true, false, false),
      ] : []) : [
        ("home-light", TaskPhase.idle, 0, true, false, false),
        ("home-dark", .idle, 0, true, true, false),
        ("setup", .idle, 0, false, false, false),
        ("running", .acting, 0, true, true, false),
        ("question", .waiting, 0, true, false, false),
        ("paused", .paused, 0, true, false, false),
        ("failure", .failed, 0, true, true, false),
        ("completed", .completed, 0, true, false, false),
        ("device", .idle, 2, true, false, false),
        ("account", .idle, 1, true, false, false),
        ("models", .idle, 3, true, false, false),
        ("history", .idle, 4, true, false, false),
        ("notifications", .idle, 5, true, false, false),
        ("language", .idle, 6, true, false, false),
        ("large-text", .waiting, 0, true, false, true),
      ]
      for (name, phase, tab, ready, dark, large) in states {
        guard UIApplication.shared.applicationState == .active else { break }
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        if name.hasSuffix("-narrow") { window.frame.size.width = 320 }
        window.windowLevel = .alert + 1
        defer {
          window.isHidden = true
          window.rootViewController = nil
        }
        let model = PhoneAgentModel(interfacePreview: phase)
        let account = SubscriptionModel(interfacePreview: ready)
        let probe = ProbeModel(interfacePreview: ready)
        let selection = ModelSelection(interfacePreview: true)
        var evidence = DevicePreparation()
        if ready { evidence.succeed() }
        let preparation = PhonePreparationModel(preview: evidence)
        let root = InterfaceSnapshotRoot(
          model: model, account: account, probe: probe, selection: selection, preparation: preparation, tab: tab
        )
        .environment(\.locale, Locale(identifier: language))
        .environment(\.dynamicTypeSize, large ? .accessibility1 : .large)
        .preferredColorScheme(dark ? .dark : .light).tint(SoloStyle.accent)
        .allowsHitTesting(false)
        .transaction { $0.disablesAnimations = true }
        let controller = UIHostingController(rootView: root)
        window.rootViewController = controller
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        window.makeKeyAndVisible()
        try? await Task.sleep(for: .milliseconds(bilingual ? 900 : 2500))
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        window.layoutIfNeeded()
        if name == "markdown-right" || name == "code-right" {
          func scrolls(_ view: UIView) -> [UIScrollView] {
            ((view as? UIScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrolls)
          }
          // Explicit fixture only: scroll the table, never the user's real chat.
          let candidates = scrolls(window).filter { $0.contentSize.width > $0.bounds.width + 10 }
          for scroll in candidates {
            let maximum = max(0, scroll.contentSize.width - scroll.bounds.width + scroll.adjustedContentInset.right)
            scroll.setContentOffset(CGPoint(x: maximum, y: scroll.contentOffset.y), animated: false)
            tableScrollChecks.append(["language": language, "scene": name, "viewport": scroll.bounds.width,
              "content": scroll.contentSize.width, "offset": scroll.contentOffset.x])
          }
          try? await Task.sleep(for: .milliseconds(200))
        }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
          window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        if let png = image.pngData() {
          do {
            try png.write(to: directory.appendingPathComponent(language + "-" + name + ".png"), options: .atomic)
            files.append(language + "-" + name + ".png")
          } catch {}
        }
      }
      }
      previous.makeKeyAndVisible()
      let report: [String: Any] = [
        "fixture_only": true, "phone_commands": 0, "model_requests": 0, "screenshots": files,
        "generated_at": ISO8601DateFormatter().string(from: Date()), "snapshot_harness": 5, "table_scroll_checks": tableScrollChecks, "languages": languages, "original_language_restored": true,
      ]
      if let data = try? JSONSerialization.data(
        withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      {
        try? data.write(to: directory.appendingPathComponent("report.json"), options: .atomic)
      }
    }
  }

  private struct InterfaceSnapshotRoot: View {
    let model: PhoneAgentModel
    let account: SubscriptionModel
    let probe: ProbeModel
    let selection: ModelSelection
    let preparation: PhonePreparationModel
    let tab: Int
    var body: some View {
      Group {
        if tab == 3 {
          ModelPickerView(selection: selection)
        } else if tab == 4 {
          ChatHistoryView(model: model)
        } else if tab == 5 {
          TaskNotificationSettingsView()
        } else if tab == 8 {
          MarkdownPreview(variant: 1)
        } else if tab == 9 {
          MarkdownPreview(variant: 2)
        } else if tab == 10 {
          MarkdownPreview(variant: 3)
        } else if tab == 11 {
          MarkdownPreview(variant: 4)
        } else if tab == 7 {
          MarkdownPreview()
        } else if tab == 6 {
          LanguageSettingsView()
        } else {
          TabView(selection: .constant(tab)) {
            PhoneAgentView(model: model, account: account, probe: probe, modelSelection: selection, preparation: preparation)
              .tabItem { Label(L10n.text("任务"), systemImage: "sparkles") }.tag(0)
            SubscriptionView(model: account, probe: probe)
              .tabItem { Label(L10n.text("账号"), systemImage: "person.crop.circle") }.tag(1)
            DeviceView(model: probe, preparation: preparation)
              .tabItem { Label(L10n.text("设备"), systemImage: "iphone") }.tag(2)
          }
        }
      }.overlay(alignment: .top) {
        Text(L10n.text("界面预览 · 示例内容")).font(.system(size: 9)).foregroundStyle(.secondary)
          .padding(3).background(.ultraThinMaterial, in: Capsule()).allowsHitTesting(false)
      }
    }
  }
#endif
