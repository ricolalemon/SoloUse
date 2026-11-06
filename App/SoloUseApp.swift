import BackgroundTasks
import Combine
import SwiftUI
import UIKit

@main
struct SoloUseApp: App {
  @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
  @StateObject private var language = LanguageSettings.shared
  @Environment(\.scenePhase) private var scenePhase
  var body: some Scene {
    WindowGroup {
      SoloUseRootView()
        .environment(\.locale, language.preference.locale)
        .id(language.preference.rawValue)
    }
    .onChange(of: scenePhase) { _, phase in
      ProbeModel.shared.log(["kind": "lifecycle", "state": String(describing: phase)])
      if phase == .background {
        PhonePreparationModel.shared.invalidate()
        PhoneAgentModel.shared.didEnterBackground()
      }
      if phase == .active {
        PhoneAgentModel.shared.willEnterForeground(source: "scene_phase_active")
      }
    }
  }
}

struct SoloUseRootView: View {
  @Environment(\.scenePhase) private var scenePhase
  @ObservedObject private var subscription = SubscriptionModel.shared
  @ObservedObject private var agent = PhoneAgentModel.shared
  @ObservedObject private var probe = ProbeModel.shared
  @ObservedObject private var preparation = PhonePreparationModel.shared
  @State private var selection = 0
  var body: some View {
    TabView(selection: $selection) {
      PhoneAgentView(
        model: agent, account: subscription, probe: ProbeModel.shared,
        onOpenAccount: { selection = 1 }, onOpenDevice: { selection = 2 }
      )
      .tabItem { Label(L10n.text("任务"), systemImage: "sparkles") }.tag(0)
      SubscriptionView(model: subscription, probe: ProbeModel.shared)
        .tabItem { Label(L10n.text("账号"), systemImage: "person.crop.circle") }.tag(1)
      DeviceView(model: ProbeModel.shared, onOpenAccount: { selection = 1 })
        .tabItem { Label(L10n.text("设备"), systemImage: "iphone") }.tag(2)
    }
    .tint(SoloStyle.accent)
    .task(id: canRefreshModels) {
      #if DEBUG
        // Explicit diagnostics/fixtures own their network activity.
        if ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--solouse-") }) {
          return
        }
      #endif
      if canRefreshModels { await ModelSelection.shared.refreshIfNeeded() }
    }
    .task {
      #if DEBUG
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--solouse-context-check"),
          ProcessInfo.processInfo.arguments.indices.contains(index + 1) {
          await ContextRecoverySelfTest.run(ProcessInfo.processInfo.arguments[index + 1])
          return
        }
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--solouse-demo-followup"),
          ProcessInfo.processInfo.arguments.indices.contains(index + 2),
          let chatID = UUID(uuidString: ProcessInfo.processInfo.arguments[index + 1]) {
          await DemoTaskLauncher.run(goal: ProcessInfo.processInfo.arguments[index + 2], continuing: chatID)
          return
        }
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--solouse-demo-task"),
          ProcessInfo.processInfo.arguments.indices.contains(index + 1) {
          await DemoTaskLauncher.run(goal: ProcessInfo.processInfo.arguments[index + 1])
          return
        }
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--solouse-history-check"),
          ProcessInfo.processInfo.arguments.indices.contains(index + 1) {
          ChatHistorySelfTest.run(ProcessInfo.processInfo.arguments[index + 1])
          return
        }
        if ProcessInfo.processInfo.arguments.contains("--solouse-tree-tool-check") {
          await TreeToolSelfTest.run()
          return
        }
        if ProcessInfo.processInfo.arguments.contains("--solouse-tree-fixture"), !agent.busy, agent.pendingHandoff == nil {
          probe.start("tree_fixture")
          return
        }
        if ProcessInfo.processInfo.arguments.contains("--solouse-tree-probe"), !agent.busy, agent.pendingHandoff == nil {
          probe.start("tree_probe")
          return
        }
        if ProcessInfo.processInfo.arguments.contains("--solouse-ui-snapshots") {
          await InterfaceSnapshotSuite.run()
          return
        }
        if ProcessInfo.processInfo.arguments.contains("--solouse-observation-benchmark") {
          for _ in 0..<30 {
            if UIApplication.shared.applicationState == .active { break }
            try? await Task.sleep(for: .milliseconds(100))
          }
          if UIApplication.shared.applicationState == .active { await ObservationBenchmark.run() }
        }
        if ProcessInfo.processInfo.arguments.contains("--solouse-transport-benchmark") {
          await TransportBenchmark.run()
        }
        if ProcessInfo.processInfo.arguments.contains("--solouse-script-model-check") {
          await ScriptModelSelfTest.run()
        }
        if ProcessInfo.processInfo.arguments.contains("--solouse-script-output-check") {
          await ScriptOutputSelfTest.run()
        }
        if ProcessInfo.processInfo.arguments.contains("--solouse-image-pipeline-check") {
          await ImagePipelineSelfTest.run()
        }
        if ProcessInfo.processInfo.arguments.contains("--solouse-input-probe") {
          await InputProbeConsole.run()
        }
        if ProcessInfo.processInfo.arguments.contains("--solouse-agent-paste-check") {
          // Explicit developer fixture using the ordinary agent/model loop.
          // The goal contains no tool choice, coordinates or dialog instructions.
          for _ in 0..<30 {
            if UIApplication.shared.applicationState == .active { break }
            try? await Task.sleep(for: .milliseconds(100))
          }
          guard UIApplication.shared.applicationState == .active, !agent.busy,
            agent.pendingHandoff == nil, !probe.busy else { return }
          agent.taskText = "请打开 SoloUse Lab，在唯一的输入框中输入「模型验证🙂44」，确认输入框文字正确后结束。"
          agent.start()
          return
        }
        if ProcessInfo.processInfo.arguments.contains("--solouse-chat-check-restore") {
          try? ChatContinuationSelfTest.restore()
          return
        }
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--solouse-chat-check-marker"),
          ProcessInfo.processInfo.arguments.indices.contains(index + 1) {
          await ChatContinuationSelfTest.run(
            afterRelaunch: ProcessInfo.processInfo.arguments.contains("--solouse-chat-check-after-relaunch"),
            marker: ProcessInfo.processInfo.arguments[index + 1])
          return
        }
        if ProcessInfo.processInfo.arguments.contains("--solouse-cache-affinity-benchmark") {
          await CacheAffinityBenchmark.run()
        }
        if ProcessInfo.processInfo.arguments.contains("--solouse-runtime-control-check") {
          for _ in 0..<30 {
            if UIApplication.shared.applicationState == .active { break }
            try? await Task.sleep(for: .milliseconds(100))
          }
          if UIApplication.shared.applicationState == .active { await RuntimeControlSelfTest.run() }
        }
        if ProcessInfo.processInfo.arguments.contains("--solouse-notification-test") {
          await TaskNotifications.shared.sendReplyTest()
        }
        if ProcessInfo.processInfo.arguments.contains("--solouse-model-catalog-check") {
          await ModelSelectionSelfTest.run(vision: false)
        }
        if ProcessInfo.processInfo.arguments.contains("--solouse-model-vision-check") {
          await ModelSelectionSelfTest.run(vision: true)
        }
        if ProcessInfo.processInfo.arguments.contains("--solouse-fast-benchmark") {
          for _ in 0..<30 {
            if UIApplication.shared.applicationState == .active { break }
            try? await Task.sleep(for: .milliseconds(100))
          }
          await FastModeBenchmark.run()
        }
        if ProcessInfo.processInfo.arguments.contains("--solouse-debug-self-test") {
          await DebugTraceSelfTest.run()
        }
        if ProcessInfo.processInfo.arguments.contains("--solouse-health-check") {
          selection = 2
          for _ in 0..<30 {
            if UIApplication.shared.applicationState == .active { break }
            try? await Task.sleep(for: .milliseconds(100))
          }
          if UIApplication.shared.applicationState == .active { PhoneHealthCheck.shared.start() }
        }
      #endif
    }
    .onChange(of: agent.openRequest) { _, _ in selection = 0 }
    #if DEBUG
      .onReceive(TaskNotifications.shared.$replyTestOpenRequest.dropFirst()) { _ in selection = 0 }
    #endif
    .onReceive(
      NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
    ) { _ in agent.didEnterBackground() }
    .onReceive(
      NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
    ) { _ in agent.willEnterForeground(source: "application_will_enter_foreground") }
    .onReceive(NotificationCenter.default.publisher(for: UIScene.willEnterForegroundNotification)) {
      _ in agent.willEnterForeground(source: "scene_will_enter_foreground")
    }
  }
  private var canRefreshModels: Bool {
    scenePhase == .active && subscription.signedIn && !subscription.busy
      && !agent.busy && !probe.busy && !preparation.busy
  }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    MainActor.assumeIsolated { TaskNotifications.shared.configure() }
    ProbeModel.shared.registerBackgroundTask()
    return true
  }
}

final class ProbeModel: NSObject, ObservableObject, NetServiceDelegate {
  static let shared = ProbeModel()
  @Published var busy = false
  @Published var paired = false
  @Published var pin = ""
  @Published var phase = "Ready to test"
  @Published var lines: [String] = []
  @Published var frame: UIImage?
  @Published var packets = 0
  @Published var touches = 0
  @Published var host = "10.7.0.1"
  @Published var bgStatus = "Not requested"
  @Published var backgroundSeconds = 300
  var target = CGPoint(x: 0.5, y: 0.5)
  private var service: NetService?
  private var timer: Timer?
  private var task: BGContinuedProcessingTask?
  private var pendingMode: String?
  private var activeMode: String?
  private var activeSessionID: String?
  private var endpointDiscovery: Task<Void, Never>?
  @Published private(set) var developerPort: UInt16 = 49152
  @Published private(set) var developerPortDiscovered = false
  private var sessionReadOnly = true
  private var startedAt = Date()
  private var requestGeneration = UUID()
  private var backgroundStartedAt: Date?
  private var sessionProgress = PhoneSessionProgress()
  private var terminationReason: String?
  private var agentPresentation: (phase: TaskPhase, detail: String, turns: Int, calls: Int)?
  private var ordinaryTask: UIBackgroundTaskIdentifier = .invalid
  private let backgroundID = RuntimeIdentifiers.backgroundTask
  let directory: URL
  private let logURL: URL

  #if DEBUG
    init(interfacePreview paired: Bool) {
      directory = FileManager.default.temporaryDirectory.appendingPathComponent("SoloUseUIPreview")
      logURL = directory.appendingPathComponent("unused.jsonl")
      super.init()
      self.paired = paired
      self.phase = paired ? "配对记录已保存" : "等待首次配对"
    }
  #endif

  override init() {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[
      0]
    directory = support.appendingPathComponent("SoloUsePrivate", isDirectory: true)
    logURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("diagnostics.jsonl")
    super.init()
    try? FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    var resourceURL = directory
    var attributes = URLResourceValues()
    attributes.isExcludedFromBackup = true
    try? resourceURL.setResourceValues(attributes)
    refreshPaired()
    timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
      self?.poll()
    }
    log([
      "kind": "app_start",
      "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        ?? "dev", "system": UIDevice.current.systemVersion,
    ])
  }

  func refreshPaired() {
    guard let data = try? Data(contentsOf: directory.appendingPathComponent("pairing.plist")),
      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any]
    else {
      paired = false
      return
    }
    paired = plist["alt_irk"] != nil
  }

  func registerBackgroundTask() {
    let accepted = BGTaskScheduler.shared.register(
      forTaskWithIdentifier: backgroundID, using: .main
    ) { [weak self] t in
      guard let self, let t = t as? BGContinuedProcessingTask else {
        t.setTaskCompleted(success: false)
        return
      }
      guard self.busy, self.pendingMode != nil else {
        t.setTaskCompleted(success: false)
        return
      }
      self.task = t
      self.endOrdinaryTask()
      t.progress.totalUnitCount =
        self.activeMode == "background"
        ? Int64(self.backgroundSeconds + 10)
        : (self.activeMode == "session" ? self.sessionProgress.total : 100)
      t.progress.completedUnitCount = 1
      t.expirationHandler = {
        DispatchQueue.main.async {
          self.bgStatus = "Expired"
          self.terminationReason = "系统结束了后台会话，请检查手机后重试"
          self.log([
            "kind": "background_expired",
            "progress_completed": self.task?.progress.completedUnitCount ?? 0,
            "progress_total": self.task?.progress.totalUnitCount ?? 0,
          ])
          self.stop(reason: "background_expiration")
        }
      }
      self.bgStatus = "Active"
      if self.activeMode == "session", let state = self.agentPresentation {
        self.agentPresentation = nil
        self.presentAgentStatus(
          state.phase, detail: state.detail, turns: state.turns, calls: state.calls)
      }
      self.log(["kind": "background_granted", "total_progress_units": t.progress.totalUnitCount])
      if let mode = self.pendingMode {
        self.pendingMode = nil
        self.startNative(mode)
      }
    }
    log(["kind": "background_registered", "accepted": accepted])
  }

  func start(_ mode: String, sessionID: String? = nil, readOnly: Bool = true) {
    guard !busy else { return }
    busy = true
    pin = ""
    frame = nil
    packets = 0
    pendingMode = mode
    activeMode = mode
    activeSessionID = sessionID
    sessionReadOnly = readOnly
    startedAt = Date()
    backgroundStartedAt = nil
    sessionProgress = PhoneSessionProgress()
    terminationReason = nil
    let generation = UUID()
    requestGeneration = generation
    log([
      "kind": "test_start", "mode": mode, "background_seconds": backgroundSeconds,
      "endpoint": mode == "direct_probe"
        ? "self_interfaces" : (host == "127.0.0.1" ? "direct_loopback" : "local_vpn"),
    ])
    UIApplication.shared.isIdleTimerDisabled = true
    ordinaryTask = UIApplication.shared.beginBackgroundTask(withName: "SoloUse setup") {
      [weak self] in
      DispatchQueue.main.async { self?.endOrdinaryTask() }
    }
    let request = BGContinuedProcessingTaskRequest(
      identifier: backgroundID,
      title: L10n.text(mode == "session" ? "SoloUse 任务" : "SoloUse 设备测试"),
      subtitle: L10n.text(mode == "pair" ? "请打开开发者模式配对" : "由你启动的手机操作"))
    request.strategy = .fail
    bgStatus = "Requested"
    DispatchQueue.global(qos: .userInitiated).async {
      BGTaskScheduler.shared.submitTaskRequest(request) { error in
        DispatchQueue.main.async {
          guard let error, self.busy, self.requestGeneration == generation, self.pendingMode == mode
          else { return }
          self.bgStatus = "Unavailable: foreground only"
          self.log(["kind": "background_rejected", "error": error.localizedDescription])
          self.pendingMode = nil
          // Foreground probes remain useful when continued processing is denied.
          if ["background", "session"].contains(mode) {
            self.phase = "Background task denied"
            self.finish(false)
            return
          }
          self.startNative(mode)
        }
      }
    }
  }

  func presentAgentStatus(_ phase: TaskPhase, detail: String, turns: Int, calls: Int) {
    let publicDetail = phase.terminal || phase == .waiting ? phase.label : detail
    let state = (phase: phase, detail: String(publicDetail.prefix(60)), turns: turns, calls: calls)
    guard
      agentPresentation?.phase != phase || agentPresentation?.detail != state.detail
        || agentPresentation?.turns != turns || agentPresentation?.calls != calls
    else { return }
    agentPresentation = state
    guard activeMode == "session", let task else { return }
    // The continued-processing task owns the system Live Activity. Reuse it,
    // rather than creating a competing second island. No sensitive text here.
    task.updateTitle(
      "SoloUse · " + L10n.text(phase.label),
      subtitle: L10n.text(state.detail) + L10n.text(" · 会话 \(sessionProgress.completed) 秒 · \(calls) 次调用"))
    task.progress.totalUnitCount = sessionProgress.total
    task.progress.completedUnitCount = sessionProgress.completed
  }

  private func startNative(_ mode: String) {
    guard mode != "pair", mode != "direct_probe" else {
      launchNative(mode, port: 49152)
      return
    }
    let generation = requestGeneration
    phase = "正在发现本机开发服务…"
    endpointDiscovery = Task { @MainActor in
      let started = ProcessInfo.processInfo.systemUptime
      let discovery = LocalDeveloperEndpoint()
      let discovered = await discovery.discover()
      guard !Task.isCancelled, busy, requestGeneration == generation else { return }
      endpointDiscovery = nil
      developerPort = discovered ?? 49152
      developerPortDiscovered = discovered != nil
      log([
        "kind": "local_developer_endpoint", "port": Int(developerPort),
        "source": discovered == nil ? "legacy_fallback" : "own_bonjour_service",
        "services_found": discovery.servicesFound, "services_resolved": discovery.servicesResolved,
        "discovery_ms": Int((ProcessInfo.processInfo.systemUptime - started) * 1000),
      ])
      launchNative(mode, port: developerPort)
    }
  }

  private func launchNative(_ mode: String, port: UInt16) {
    var config: [String: Any] = [
      "mode": mode, "directory": directory.path, "bundle_prefix": RuntimeIdentifiers.prefix, "host": mode == "session" ? "10.7.0.1" : host,
      "port": Int(port), "x": target.x, "y": target.y, "background_seconds": backgroundSeconds,
    ]
    if let activeSessionID {
      config["session_id"] = activeSessionID
      config["read_only"] = sessionReadOnly
    }
    #if DEBUG
      if ProcessInfo.processInfo.arguments.contains("--solouse-input-probe") {
        let slow = ProcessInfo.processInfo.arguments.contains("--probe-keyboard-slow")
        config["keyboard_tuning"] = ["setup_ms": slow ? 1000 : 100,
          "paste_ms": slow ? 2000 : 500,
          "indigo": ProcessInfo.processInfo.arguments.contains("--probe-keyboard-indigo"),
          "paste_indigo": !ProcessInfo.processInfo.arguments.contains("--probe-paste-hardware"),
          "keep_connected": ProcessInfo.processInfo.arguments.contains("--probe-keyboard-persistent")]
      }
    #endif
    guard let data = try? JSONSerialization.data(withJSONObject: config),
      let json = String(data: data, encoding: .utf8)
    else {
      finish(false)
      return
    }
    let result = json.withCString { solo_start($0) }
    if result != 0 {
      log(["kind": "start_failed", "code": result])
      finish(false)
    }
  }

  func stop(reason: String = "device_stop_button") {
    MainActor.assumeIsolated {
      TaskDiagnostics.shared.record("native_cancel_requested", ["source": .string(reason)])
    }
    if let discovery = endpointDiscovery {
      endpointDiscovery = nil
      discovery.cancel()
      finish(false)
      return
    }
    solo_cancel()
    if pendingMode != nil {
      pendingMode = nil
      BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: backgroundID)
      finish(false)
    }
  }

  private func finish(_ ok: Bool) {
    let wasSession = activeMode == "session"
    service?.stop()
    service = nil
    pin = ""
    busy = false
    let expectedEnd =
      wasSession
      && [.pausing, .paused, .waiting, .completed, .stopped].contains(
        agentPresentation?.phase ?? .idle)
    if ok || expectedEnd, let task {
      task.progress.totalUnitCount = max(1, task.progress.completedUnitCount)
      task.progress.completedUnitCount = task.progress.totalUnitCount
    }
    task?.setTaskCompleted(success: ok || expectedEnd)
    task = nil
    activeMode = nil
    activeSessionID = nil
    pendingMode = nil
    if bgStatus == "Active" { bgStatus = "Completed" }
    UIApplication.shared.isIdleTimerDisabled = false
    endOrdinaryTask()
    refreshPaired()
    if wasSession {
      MainActor.assumeIsolated { NativePhoneDriver.shared.ended(terminationReason ?? phase) }
    }
  }

  private func endOrdinaryTask() {
    if ordinaryTask != .invalid {
      UIApplication.shared.endBackgroundTask(ordinaryTask)
      ordinaryTask = .invalid
    }
  }

  private func poll() {
    if busy, pendingMode != nil, Date().timeIntervalSince(startedAt) > 25 {
      phase = "系统未启动后台会话，请稍后重试"
      stop(reason: "background_start_timeout")
    }
    while let ptr = solo_poll() {
      let string = String(cString: ptr)
      solo_string_free(ptr)
      guard let data = string.data(using: .utf8),
        let e = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let kind = e["kind"] as? String
      else { continue }
      MainActor.assumeIsolated { TaskDiagnostics.shared.native(e) }
      switch kind {
      case "advertise":
        guard let port = e["port"] as? Int, let name = e["name"] as? String,
          let records = e["txt"] as? [[String]]
        else { continue }
        let service = NetService(
          domain: "local.", type: "_remotepairing-pairable-host._tcp.", name: name,
          port: Int32(port))
        var txt: [String: Data] = [:]
        for item in records where item.count == 2 { txt[item[0]] = Data(item[1].utf8) }
        service.setTXTRecord(NetService.data(fromTXTRecord: txt))
        service.delegate = self
        self.service = service
        service.publish()
        log(["kind": "pair_advertisement_requested"])
      case "pin":
        pin = e["pin"] as? String ?? ""
        task?.updateTitle(L10n.text("SoloUse pairing PIN"), subtitle: pin)
        phase = "Enter the PIN in Settings"
      // Never include setup codes in the diagnostic file.
      case "phase":
        phase = e["stage"] as? String ?? ""
        if let task, !["background", "session"].contains(activeMode ?? "") {
          task.progress.completedUnitCount = min(90, task.progress.completedUnitCount + 3)
        }
        log(e)
      case "rsd":
        MainActor.assumeIsolated { PhonePreparationModel.shared.receivedRSD() }
        log(e)
      case "paired":
        paired = true
        phase = "Pairing saved on this iPhone"
        log(e)
      case "screenshot":
        if let name = e["file"] as? String,
          ["before.png", "after.png", "direct.png", "background-checkpoint.png"].contains(name)
        {
          frame = UIImage(contentsOfFile: directory.appendingPathComponent(name).path)
        }
        log(e)
      case "stream":
        packets = e["rtp_packets"] as? Int ?? packets
        if activeMode == "background" {
          let seconds = backgroundStartedAt.map { Int(Date().timeIntervalSince($0)) } ?? 0
          task?.progress.completedUnitCount = Int64(min(backgroundSeconds + 5, 5 + seconds))
          phase = "后台测试：\(seconds) / \(backgroundSeconds) 秒"
          if seconds % 15 == 0 {
            task?.updateTitle(
              L10n.text("SoloUse 后台测试"), subtitle: L10n.text("\(seconds) / \(backgroundSeconds) 秒 · RTP \(packets)"))
          }
        } else if activeMode == "session" {
          let seconds = e["seconds"] as? Int ?? 0
          sessionProgress.observe(seconds: seconds, packets: packets)
          task?.progress.totalUnitCount = sessionProgress.total
          task?.progress.completedUnitCount = sessionProgress.completed
          if seconds % 5 == 0, let state = agentPresentation {
            task?.updateTitle(
              "SoloUse · " + L10n.text(state.phase.label),
              subtitle: L10n.text(state.detail)
                + L10n.text(" · 会话 \(sessionProgress.completed) 秒 · \(state.calls) 次调用"))
          }
        } else if let seconds = e["seconds"] as? Int {
          task?.progress.completedUnitCount = Int64(min(95, 5 + seconds * 2))
        }
        log(e)
      case "background_watch_completed":
        phase = "后台测试完成：\((e["elapsed_ms"] as? Int ?? 0)/1000) 秒"
        log(e)
      case "action_sent":
        if activeMode == "background", e["action"] as? String == "home" {
          backgroundStartedAt = Date()
        }
        log(e)
      case "session_ready", "command_result":
        // Do not write screen content, task arguments, or app inventory into logs.
        log([
          "kind": kind, "id": e["id"] as? String ?? "", "status": e["status"] as? String ?? "ready",
        ])
        MainActor.assumeIsolated { NativePhoneDriver.shared.receive(e) }
      case "error":
        phase = PhoneConnectionFailure.displayMessage(
          terminationReason ?? (e["message"] as? String ?? "手机连接失败"))
        log(e)
      case "finished":
        let ok = e["ok"] as? Bool ?? false
        log(e)
        finish(ok)
      default: log(e)
      }
    }
  }

  func touched() {
    touches += 1
    log(["kind": "target_touch_observed", "count": touches, "during_test": busy])
  }

  func log(_ fields: [String: Any]) {
    if let kind = fields["kind"] as? String,
      ["lifecycle", "background_granted", "background_rejected", "background_expired"].contains(
        kind), let value = try? JSONValue(fields), let object = value.object
    {
      MainActor.assumeIsolated { TaskDiagnostics.shared.record(kind, object) }
    }
    var entry =
      (try? DebugPrivacy.value(JSONValue(fields)).foundation()) as? [String: Any] ?? [
        "kind": "diagnostic_encoding_failed"
      ]
    entry["observed_timestamp_ms"] = Int64(Date().timeIntervalSince1970 * 1000)
    entry["system_uptime_ms"] = Int64(ProcessInfo.processInfo.systemUptime * 1000)
    entry["received_at"] = ISO8601DateFormatter().string(from: Date())
    entry["app_state"] = UIApplication.shared.applicationState.rawValue
    guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]),
      let line = String(data: data, encoding: .utf8)
    else { return }
    lines.append(line)
    if lines.count > 120 { lines.removeFirst(lines.count - 120) }
    if !FileManager.default.fileExists(atPath: logURL.path) {
      FileManager.default.createFile(atPath: logURL.path, contents: nil)
    }
    if let file = try? FileHandle(forWritingTo: logURL) {
      defer { try? file.close() }
      _ = try? file.seekToEnd()
      try? file.write(contentsOf: Data((line + "\n").utf8))
    }
  }
  func netServiceDidPublish(_ sender: NetService) { log(["kind": "pair_advertisement_published"]) }
  func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
    log(["kind": "bonjour_failed", "error": errorDict])
    stop(reason: "bonjour_publish_failed")
  }
}

private struct TargetFrameKey: PreferenceKey {
  static var defaultValue = CGRect.zero
  static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

struct ProbeView: View {
  @ObservedObject var model: ProbeModel
  @ObservedObject private var health = PhoneHealthCheck.shared
  @ObservedObject private var preparation = PhonePreparationModel.shared
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          VStack(alignment: .leading) {
            Text(L10n.text("设备诊断")).font(.title.bold())
            Text(L10n.text("连接、触控与后台运行测试")).font(.subheadline).foregroundStyle(.secondary)
          }
          Spacer()
          if model.busy { ProgressView() }
        }
        Text(L10n.text("首次配对和连接诊断。日常任务在“任务”页启动。"))
          .font(.caption).foregroundStyle(.secondary)
        Picker(L10n.text("Connection"), selection: $model.host) {
          Text("LocalDevVPN").tag("10.7.0.1")
          Text(L10n.text("Direct loopback")).tag("127.0.0.1")
        }.pickerStyle(.segmented).disabled(model.busy)
        HStack {
          Label(
            model.paired ? L10n.text("Paired") : L10n.text("Not paired"),
            systemImage: model.paired ? "checkmark.circle.fill" : "circle")
          Spacer()
          Text("RTP: \(model.packets)").monospacedDigit()
        }.font(.caption)
        if !model.pin.isEmpty {
          Text(model.pin).font(.system(size: 36, weight: .bold, design: .monospaced))
          Text(L10n.text("把此 PIN 输入到设置中的“与 SoloUse 配对”。")).font(.caption)
        }
        HStack {
          Button(L10n.text("1. 本机配对")) { model.start("pair") }.disabled(model.busy || model.paired)
          Button(L10n.text("2. 连接与截图")) { model.start("probe") }.disabled(model.busy || !model.paired)
        }.buttonStyle(.bordered)
        HStack {
          Button(L10n.text("3. 测试一次点击")) { model.start("touch") }.disabled(model.busy || !model.paired)
          Button(L10n.text("4. 后台 \(model.backgroundSeconds / 60) 分钟")) { model.start("background") }.disabled(
            model.busy || !model.paired)
        }.buttonStyle(.bordered)
        Picker(L10n.text("后台测试时长"), selection: $model.backgroundSeconds) {
          Text(L10n.text("1 分钟")).tag(60)
          Text(L10n.text("5 分钟")).tag(300)
          Text(L10n.text("10 分钟")).tag(600)
        }.pickerStyle(.segmented).disabled(model.busy)
        HStack {
          Button(L10n.text("通用工具 / 后台自检")) { health.start() }.disabled(
            model.busy || health.busy || !model.paired)
          if health.busy { Button(L10n.text("停止自检")) { health.stop() } }
        }.buttonStyle(.bordered)
        if !health.status.isEmpty { Text(L10n.text(health.status)).font(.caption) }
        Button(L10n.text("无 VPN 地址对照")) { model.start("direct_probe") }.buttonStyle(.bordered).disabled(
          model.busy || !model.paired)
        Button(action: model.touched) {
          VStack {
            Text(L10n.text("点击测试区域")).font(.headline)
            Text(L10n.text("收到点击：\(model.touches)")).monospacedDigit()
          }
          .frame(maxWidth: .infinity).frame(height: 72)
        }.buttonStyle(.borderedProminent)
          .background(
            GeometryReader { p in
              Color.clear.preference(key: TargetFrameKey.self, value: p.frame(in: .global))
            }
          )
          .onPreferenceChange(TargetFrameKey.self) { rect in
            guard
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive })
            else { return }
            let bounds = scene.screen.bounds
            guard bounds.width > 0, bounds.height > 0 else { return }
            model.target = CGPoint(x: rect.midX / bounds.width, y: rect.midY / bounds.height)
          }
        Text(L10n.text(model.phase)).font(.caption.monospaced()).lineLimit(4)
        Text(L10n.text("Background: \(model.bgStatus)")).font(.caption).foregroundStyle(.secondary)
        HStack {
          Button(L10n.text("停止")) { model.stop() }.tint(.red).disabled(!model.busy)
          Spacer()
          if let image = model.frame {
            Image(uiImage: image).resizable().scaledToFit().frame(height: 65).accessibilityLabel(
              L10n.text("Captured device screen"))
          }
        }.buttonStyle(.bordered)
        ScrollView {
          Text(model.lines.suffix(12).joined(separator: "\n")).font(
            .system(size: 9, design: .monospaced)
          ).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        }
        .frame(height: 180).padding(8).background(.black.opacity(0.04)).clipShape(
          RoundedRectangle(cornerRadius: 8))
      }.padding(20)
    }.background(SoloStyle.canvas).disabled(preparation.busy)
  }
}
