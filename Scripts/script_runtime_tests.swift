import Foundation

private func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
  if !value() { throw AgentLoopError.protocolError(message) }
}
private func script(_ id: String, _ code: String) throws -> AgentToolCall {
  .init(
    id: id, name: "phone_exec_js", arguments: try JSONValue.object(["code": .string(code)]).text())
}
private func text(_ result: AgentToolResult) -> String {
  result.content.compactMap { $0["text"].string }.joined(separator: "\n")
}
@MainActor private final class Driver: PhoneDriver {
  var actions: [JSONValue] = []
  var afterAction: (() -> Void)?
  var status = "executed"
  var frames = 0
  func perform(action: JSONValue, id: String) async throws -> PhoneDriverReply {
    actions.append(action)
    afterAction?()
    if status != "executed" { return .init(status: status, value: .null) }
    if ["observe", "read_tree"].contains(action["op"].string ?? "") {
      frames += 1
      return .init(
        status: "executed",
        value: .object(["frame_id": .string("f\(frames)"), "width": .number(101), "height": .number(201)]),
        images: [
          .object([
            "type": .string("input_image"), "image_url": .string("data:image/png;base64,fixture\(frames)"),
          ])
        ])
    }
    if action["op"].string == "list_apps" {
      return .init(status: "executed", value: .object([
        "apps": .array((0..<100).map { .object(["id": .string("app\($0)"), "name": .string(String(repeating: "x", count: 100))]) })
      ]))
    }
    if ["paste_text", "paste_at"].contains(action["op"].string ?? "") {
      return .init(status: "executed", value: .object([
        "paste_id": .string("AA000000-0000-4000-8000-000000000001"), "clipboard_pending": .bool(true)]))
    }
    if action["op"].string == "finish_paste" {
      return .init(status: "executed", value: .object(["clipboard_pending": .bool(false), "clipboard_restored": .bool(true)]))
    }
    return .init(status: "executed", value: .object(["ok": .bool(true)]))
  }
}
@main struct ScriptRuntimeTests {
  @MainActor static func main() async throws {
    let treeDriver = Driver()
    let treeDispatcher = PhoneToolDispatcher(driver: treeDriver, automaticallyObserve: false) { _ in "fixture" }
    let treeExecutor = ScriptExecutor(phone: treeDispatcher, allowsActions: { true }, controlVersion: { 0 })
    let api = try await treeExecutor.execute(script("api", "log(Object.keys(phone));"))
    try check(text(api).contains("observe") && text(api).contains("pasteText") && !text(api).contains("readTree"),
      "Default JS API must keep screenshot/input and remove tree")
    let removedTree = try await treeExecutor.execute(script("old-tree-script", "await phone.readTree({});"))
    try check(text(removedTree).contains("script_runtime_error") && treeDriver.actions.isEmpty,
      "Old tree scripts must fail without touching the phone")
    let rawTree = try await treeExecutor.execute(script("raw-tree-script", "await __phone('read_tree',{});"))
    try check(text(rawTree).contains("Unknown phone operation") && treeDriver.actions.isEmpty,
      "Raw script bridge must not bypass the removed tree capability")
    print("PASS default JS API omits tree; old scripts and raw bridge cannot dispatch it")
    let driver = Driver()
    let gate = AgentPauseGate()
    let dispatcher = PhoneToolDispatcher(
      driver: driver, automaticallyObserve: false, allowsActions: { gate.allowsActions }, controlVersion: { gate.revision }
    ) { _ in "unused" }
    let executor = ScriptExecutor(
      phone: dispatcher, allowsActions: { gate.allowsActions }, controlVersion: { gate.revision })
    let first = try await executor.execute(
      script("one", "state.n = 40; state.frame = await phone.observe(); log('ready');"))
    try check(
      first.content.contains { $0["type"].string == "input_image" }, "Observation image omitted")
    let second = try await executor.execute(
      script(
        "two",
        "for(let i=0;i<2;i++) state.n++; log(state.n); await phone.tap({x:50,y:100,frame_id:state.frame.frame_id});"
      ))
    try check(text(second).contains("42"), "Runtime state lost")
    try check(
      driver.actions.last?["x"].number == 0.5 && driver.actions.last?["y"].number == 0.5,
      "Script bypassed pixel mapping")
    print(
      "PASS persistent variables, async phone tools, loops, screenshots and production coordinate mapping"
    )
    _ = try await executor.execute(script("paste-menu",
      "await phone.pasteAt({text:'中文🙂',x:25,y:50,frame_id:state.frame.frame_id});"))
    try check(driver.actions.last?["op"].string == "paste_at"
      && driver.actions.last?["x"].number == 0.25 && driver.actions.last?["y"].number == 0.25
      && driver.actions.last?["text"].string == "中文🙂", "Paste control bypassed coordinate mapping")
    let pasteCount = driver.actions.count
    let stalePaste = try await dispatcher.executeInSequence(.init(id: "stale-paste", name: "phone_paste_at",
      arguments: "{\"text\":\"fixture\",\"x\":25,\"y\":50,\"frame_id\":\"old-frame\"}"))
    try check(driver.actions.count == pasteCount && text(stalePaste).contains("invalid_observation"),
      "Stale paste control was allowed to change clipboard")
    print("PASS paste-control bridge preserves Unicode and rejects stale frames before clipboard mutation")
    let retained = try await executor.execute(script("held-paste",
      "state.paste=await phone.pasteText({text:'fixture',replace_all:false}); log(state.paste.clipboard_pending);"))
    try check(text(retained).contains("true"), "Pending-paste receipt lost")
    _ = try await executor.execute(script("finish-held-paste", "await phone.finishPaste({paste_id:state.paste.paste_id});"))
    try check(driver.actions.last?["op"].string == "finish_paste"
      && driver.actions.last?["paste_id"].string == "AA000000-0000-4000-8000-000000000001", "Cross-call paste token or finish bridge lost")
    let beforeBadFinish = driver.actions.count
    let badFinish = try await dispatcher.executeInSequence(.init(id: "bad-finish", name: "phone_finish_paste", arguments: "{\"paste_id\":\"bad-token\"}"))
    try check(driver.actions.count == beforeBadFinish && text(badFinish).contains("invalid_arguments"), "Malformed finish reached driver")
    var compactPaste = ScriptOutputBuffer(limits: .init(imageBytes: 1, textBytes: 0))
    compactPaste.append([.textContent(try JSONValue.object(["status": .string("executed"), "error": .null,
      "value": .object(["paste_id": .string("AA000000-0000-4000-8000-000000000001"), "clipboard_pending": .bool(true)])]).text())])
    let compactReceipt = compactPaste.content.compactMap { $0["text"].string }.joined()
    try check(compactReceipt.contains("AA000000-0000-4000-8000-000000000001") && compactReceipt.contains("clipboard_pending"), "Output trimming hid pending clipboard ownership")
    print("PASS deferred paste survives script boundaries; finish tokens validated and retained under output pressure")

    let before = driver.actions.count
    let parallel = try await executor.execute(
      script("parallel", "await Promise.all([phone.home(), phone.home()]);"))
    try check(
      text(parallel).contains("parallel") && driver.actions.count == before,
      "Parallel operations escaped")
    let unawaited = try await executor.execute(script("unawaited", "phone.home();"))
    try check(
      text(unawaited).contains("Unawaited") && driver.actions.count == before,
      "Detached operation executed")
    let boundary = try await executor.execute(
      script(
        "boundary",
        "log([typeof fetch, typeof require, typeof process, typeof SharedArrayBuffer, typeof Atomics]);"
      ))
    try check(!text(boundary).contains("function"), "Unrestricted platform API exposed")
    let nul = try await executor.execute(
      script("nul", "log('before');" + String(UnicodeScalar(0)) + "await phone.home();"))
    try check(
      text(nul).contains("invalid_script") && driver.actions.count == before,
      "Embedded NUL truncated the script")
    print("PASS no parallel/detached phone effects and no file/network/Node exports")

    let previous = driver.actions.count
    let partial = try await executor.execute(
      script(
        "partial", "await phone.home(); throw new Error('fixture failure'); await phone.home();"))
    try check(
      driver.actions.count == previous + 1 && text(partial).contains("fixture failure")
        && text(partial).contains("executed"), "Partial receipts or stop lost")
    let empty = try await executor.execute(script("empty", "log(typeof state.n);"))
    try check(text(empty).contains("undefined"), "Failed runtime was not reset")
    driver.status = "may_have_executed"
    let uncertain = try await executor.execute(
      script("uncertain", "try { await phone.home(); } catch(e) {} await phone.home();"))
    try check(
      uncertain.needsAttention && driver.actions.count == previous + 2,
      "Uncertain effect was caught and retried")
    driver.status = "executed"
    print(
      "PASS prior action receipts survive script errors and uncertain effects cannot be caught/replayed"
    )

    driver.afterAction = { gate.pause() }
    let paused = try await executor.execute(
      script("pause", "await phone.home(); await phone.home();"))
    try check(text(paused).contains("Control changed"), "Pause did not discard queued script")
    driver.afterAction = nil
    gate.resume()
    let start = Date()
    let timeout = try await executor.execute(script("loop", "while(true) {}"))
    try check(
      Date().timeIntervalSince(start) < 5 && text(timeout).contains("CPU slice"),
      "Infinite loop was not interrupted")
    print("PASS pause propagation and bounded infinite-loop execution off the UI actor")

    let running = Task { try await executor.execute(script("cancel", "while(true) {}")) }
    try await Task.sleep(for: .milliseconds(100))
    running.cancel()
    do {
      _ = try await running.value
      throw AgentLoopError.protocolError("Cancellation ignored")
    } catch is CancellationError {}
    let usable = try await executor.execute(script("after", "log('alive');"))
    try check(text(usable).contains("alive"), "Runtime failed to recover after cancellation")
    print("PASS explicit cancellation and subsequent clean runtime")

    let outputDriver = Driver()
    let outputPhone = PhoneToolDispatcher(driver: outputDriver, automaticallyObserve: false) { _ in "unused" }
    let bounded = ScriptExecutor(phone: outputPhone, allowsActions: { true }, controlVersion: { 0 },
      outputLimits: .init(imageBytes: 100, textBytes: 128))
    let many = try await bounded.execute(script("many-frames", """
      state.completed=0;
      for(let i=0;i<12;i++) {
        const f=await phone.observe();
        await phone.tap({x:50,y:100,frame_id:f.frame_id});
        await phone.wait({milliseconds:1});
        state.completed++;
      }
      """))
    try check(outputDriver.actions.count == 36 && outputDriver.frames == 12, "Eight-frame ceiling still interrupts execution")
    let images = many.content.filter { $0["type"].string == "input_image" }
    try check(images.reduce(0) { $0 + ($1["image_url"].string?.utf8.count ?? 0) } <= 100,
      "Image output exceeded its byte budget")
    try check(images.last?["image_url"].string?.hasSuffix("fixture12") == true, "Newest frame was dropped")
    let receipts = many.content.compactMap { $0["text"].string?.data(using: .utf8) }
      .compactMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
      .filter { $0["status"].string != nil && $0["script_status"] == .null }
    try check(receipts.count == 36 && receipts.allSatisfy { $0["status"].string == "executed" }, "Output trimming lost action receipts")
    let remembered = try await bounded.execute(script("many-state", "log(state.completed);"))
    try check(text(remembered).contains("Script log: 12"), "Output trimming reset state")
    try check(ScriptToolPresentation.detail(many)?.contains("变量已保留") == true, "Output trimming presented as failure")
    print("PASS game-shaped 12-observation script completes all 36 actions; newest images bounded, every receipt and variables preserved")

    let selective = try await executor.execute(script("selective", "for(let i=0;i<10;i++) await phone.observe({emit:false}); await phone.observe();"))
    try check(selective.content.filter { $0["type"].string == "input_image" }.count == 1,
      "Suppressed observations leaked images")
    let inventory = try await bounded.execute(script("inventory", "state.apps=await phone.listApps(); log(state.apps.apps.length);"))
    try check(text(inventory).contains("Script log: 100") && text(inventory).contains("output_details_omitted"),
      "Output compaction changed the full receipt delivered to JavaScript")
    print("PASS explicit image emission and full JavaScript receipts despite compact model output")

    let verbose = try await executor.execute(script("verbose", "state.afterLogs=false; log('a'); log('🙂'.repeat(20000)); for(let i=0;i<300;i++) log('line'); state.afterLogs=true;"))
    try check(!text(verbose).contains("Runtime reset") && !text(verbose).contains("�"), "Log truncation failed or broke UTF-8")
    let logState = try await executor.execute(script("log-state", "log(state.afterLogs);"))
    try check(text(logState).contains("Script log: true") && ScriptToolPresentation.detail(verbose) != nil,
      "Log volume stopped the script or lost omission reporting")
    print("PASS verbose and Unicode logs are truncated without aborting code or clearing variables")

    let segmentDriver = Driver()
    let segmentPhone = PhoneToolDispatcher(driver: segmentDriver, automaticallyObserve: false) { _ in "unused" }
    let segments = ScriptExecutor(phone: segmentPhone, allowsActions: { true }, controlVersion: { 0 })
    let segment = try await segments.execute(script("segment", "state.done=0; for(let i=0;i<70;i++){await phone.wait({milliseconds:1}); state.done++;} state.oldTail=true;"))
    try check(segmentDriver.actions.count == 64 && text(segment).contains("segment_complete"), "Segment boundary failed")
    let continued = try await segments.execute(script("continue", "if(state.done!==64 || state.oldTail!==undefined) throw new Error('Bad checkpoint'); while(state.done<70){await phone.wait({milliseconds:1});state.done++;} log(state.done);"))
    try check(segmentDriver.actions.count == 70 && text(continued).contains("Script log: 70"), "Continuation repeated effects or lost state")
    try check(ScriptToolPresentation.detail(segment)?.contains("本段操作已完成") == true, "Segment boundary displayed as failure")
    var timeline = AgentTimeline()
    let segmentCall = try script("segment-ui", "")
    timeline.accept(.toolStarted(segmentCall), turn: 1)
    timeline.accept(.toolFinished(segmentCall, segment), turn: 1)
    try check(timeline.entries.last?.state == .completed && timeline.entries.last?.text.contains("变量已保留") == true,
      "Timeline marks normal segmentation as failure")
    print("PASS 64-operation segment boundary preserves state and discards queued code; next script continues without replay")

    var clock: TimeInterval = 0
    let deadlineDriver = Driver()
    deadlineDriver.afterAction = { clock = 121 }
    let deadlinePhone = PhoneToolDispatcher(driver: deadlineDriver, automaticallyObserve: false) { _ in "unused" }
    let deadline = ScriptExecutor(phone: deadlinePhone, allowsActions: { true }, controlVersion: { 0 }, uptime: { clock })
    let timed = try await deadline.execute(script("deadline", "state.temp=1; await phone.wait({milliseconds:1}); await phone.home();"))
    try check(deadlineDriver.actions.count == 1 && text(timed).contains("script_timeout"), "Execution timeout did not stop queued action")
    let cleared = try await deadline.execute(script("deadline-cleared", "log(typeof state.temp);"))
    try check(text(cleared).contains("Script log: undefined"), "Actual timeout did not reset runtime")
    clock = 0
    let endDeadline = try await deadline.execute(script("deadline-at-end", "await phone.wait({milliseconds:1});"))
    try check(text(endDeadline).contains("script_timeout"), "Last operation completion bypassed deadline")
    print("PASS actual wall deadline remains distinct from output trimming and safely resets runtime")
  }
}
