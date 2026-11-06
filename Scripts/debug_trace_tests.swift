import Foundation

private func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
  if !value() { throw AgentLoopError.protocolError(message) }
}
private func read(_ store: DebugTraceStore) throws -> [DebugRecord] {
  try store.flush()
  return try String(
    contentsOf: store.directory.appendingPathComponent("events.jsonl"), encoding: .utf8
  )
  .split(separator: "\n").map { try JSONDecoder().decode(DebugRecord.self, from: Data($0.utf8)) }
}
@main struct DebugTraceTests {
  static func main() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "solouse-debug-tests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let traces = root.appendingPathComponent("traces")
    let id = UUID()
    let store = try DebugTraceStore(
      root: traces, runID: id, kind: "fixture", version: "0.7.0", build: "21",
      options: DebugOptions())
    let frameID = UUID().uuidString
    let frame = Data([0xff, 0xd8, 0x01, 0x02, 0xff, 0xd9])
    store.append(
      "task_started",
      .object([
        "prompt": .string("private user task"), "authorization": .string("Bearer verysecret"),
      ]))
    store.frame(
      id: frameID, data: frame,
      metadata: .object([
        "width": .number(720), "height": .number(1568), "tool_call_id": .string("observe1"),
      ]))
    store.append(
      "tool_started",
      .object([
        "tool_call_id": .string("call1"),
        "arguments": .object([
          "frame_id": .string(frameID), "x": .number(320), "y": .number(100),
          "text": .string("private input"),
        ]),
      ]))
    store.append(
      "native_command_submitted",
      .object([
        "action_id": .string("call1_0"), "native_command_id": .string("native1"),
        "action": .object([
          "x": .number(0.445), "y": .number(0.0638), "text": .string("private input"),
        ]),
      ]))
    store.append(
      "control_requested",
      .object([
        "source": .string("scene_will_enter_foreground"), "native_command_id": .string("native1"),
      ]))
    store.append(
      "native_command_failed",
      .object([
        "native_command_id": .string("native1"), "raw_error": .string("Cancelled"),
        "stage": .string("keyboard_key_down"), "cancel_requested": .bool(true),
        "input_reports_sent": .number(1),
      ]))
    store.finish("failed")
    let records = try read(store)
    try check(
      records.map(\.sequence) == Array(1...records.count), "Trace sequence is not contiguous")
    try check(records.allSatisfy { $0.runID == id }, "Events crossed task boundaries")
    let serialized = try String(
      contentsOf: store.directory.appendingPathComponent("events.jsonl"), encoding: .utf8)
    try check(
      !serialized.contains("private user task") && !serialized.contains("private input")
        && !serialized.contains("verysecret"), "Default text or authorization leaked")
    let failure = records.first { $0.kind == "native_command_failed" }!
    try check(
      failure.fields["stage"].string == "keyboard_key_down"
        && failure.fields["raw_error"].string == "Cancelled", "Failure evidence was erased")
    let saved = records.first { $0.kind == "observation" }!
    let archivedFrame = try Data(
      contentsOf: store.directory.appendingPathComponent(saved.fields["file"].string!))
    try check(
      archivedFrame == frame && saved.fields["frame_id"].string == frameID,
      "Model frame bytes or identity changed")
    print(
      "PASS ordered task/action/cancel correlation, default redaction, original error, exact frame retention"
    )

    let scriptCall = AgentToolCall(
      id: "script", name: "phone_exec_js",
      arguments: try JSONValue.object([
        "code": .string("await phone.pasteText({text:'private-script-input',replace_all:false});")
      ]).text())
    let hiddenScript = try DebugPrivacy.arguments(scriptCall, visibleText: false).text()
    try check(
      !hiddenScript.contains("private-script-input"),
      "Script literal leaked despite disabled visible text")
    let visibleScript = try DebugPrivacy.arguments(scriptCall, visibleText: true).text()
    try check(visibleScript.contains("private-script-input"), "Opt-in script diagnostics missing")
    print("PASS script literal redaction follows the visible-text setting")

    let secrets = try JSONValue([
      "refreshToken": "hidden-refresh", "api-key": "hidden-key",
      "nested": ["encrypted_content": "hidden-reasoning"],
      "message": "Authorization: Bearer hidden-bearer; key sk-fixture-secret-token-for-test",
      "text": "hello fixture",
    ])
    let safe = try DebugPrivacy.value(secrets, visibleText: true).text()
    for secret in [
      "hidden-refresh", "hidden-key", "hidden-reasoning", "hidden-bearer",
      "sk-fixture-secret-token-for-test",
    ] {
      try check(!safe.contains(secret), "Secret was not redacted: " + secret)
    }
    try check(safe.contains("hello fixture"), "Explicit visible-text option was ignored")
    try check(
      DebugPrivacy.clean("alt_irk: sensitive bytes") == "[sensitive diagnostic omitted]",
      "Pairing material was retained")
    let key = DebugPrivacy.value(.object(["key": .string("a")]))
    try check(key["key"].string == "[character]", "Single-key typing leaked")
    print("PASS nested/camel-case secret redaction and explicit visible-text capture")

    let noFrames = try DebugTraceStore(
      root: traces, runID: UUID(), kind: "fixture", version: "test", build: "1",
      options: .init(screenshots: false))
    noFrames.frame(id: UUID().uuidString, data: frame, metadata: .object([:]))
    noFrames.frame(id: "../../outside", data: frame, metadata: .object([:]))
    noFrames.finish("done")
    let disabled = try read(noFrames)
    try check(
      disabled.filter { $0.kind == "observation" }.allSatisfy { $0.fields["saved"].bool == false },
      "Disabled frames were written")
    try check(
      !FileManager.default.fileExists(
        atPath: noFrames.directory.appendingPathComponent("frames").path), "Frame opt-out ignored")
    let invalid = try DebugTraceStore(
      root: traces, runID: UUID(), kind: "fixture", version: "test", build: "1", options: .init())
    invalid.frame(id: "../../escape", data: frame, metadata: .object([:]))
    invalid.finish("done")
    let invalidRecords = try read(invalid)
    try check(invalidRecords.first?.fields["saved"].bool == false, "Invalid frame ID accepted")
    print("PASS screenshot opt-out and path validation")

    let export = root.appendingPathComponent("fixture.zip")
    try store.export(to: export)
    let unzip = Process()
    unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    unzip.arguments = ["-t", export.path]
    let out = Pipe()
    unzip.standardOutput = out
    unzip.standardError = out
    try unzip.run()
    unzip.waitUntilExit()
    try check(unzip.terminationStatus == 0, "Independent ZIP reader rejected archive")
    let fixtureDestination = URL(
      fileURLWithPath: CommandLine.arguments.dropFirst().first
        ?? root.appendingPathComponent("export.zip").path)
    if fixtureDestination != export {
      try? FileManager.default.removeItem(at: fixtureDestination)
      try FileManager.default.copyItem(at: export, to: fixtureDestination)
    }
    print("PASS standard ZIP integrity checked by system unzip")

    // Exercise a full queue followed by export; each exported line must be complete.
    let concurrent = try DebugTraceStore(
      root: traces, runID: UUID(), kind: "fixture", version: "test", build: "1", options: .init())
    DispatchQueue.concurrentPerform(iterations: 200) { i in
      concurrent.append("parallel", .object(["index": .number(Double(i))]))
    }
    try concurrent.export(to: root.appendingPathComponent("parallel.zip"))
    let concurrentRecords = try read(concurrent)
    try check(
      concurrentRecords.count == 200 && Set(concurrentRecords.map(\.sequence)).count == 200,
      "Concurrent records were lost or duplicated")
    print("PASS serialized concurrent producers and export snapshot boundary")

    let bounded = try DebugTraceStore(
      root: traces, runID: UUID(), kind: "fixture", version: "test", build: "1", options: .init())
    for _ in 0..<1200 {
      bounded.append("large", .object(["detail": .string(String(repeating: "x", count: 4096))]))
    }
    for _ in 0..<25 { bounded.frame(id: UUID().uuidString, data: frame, metadata: .object([:])) }
    bounded.finish("done")
    try bounded.flush()
    let manifest = try JSONDecoder().decode(
      DebugManifest.self,
      from: Data(contentsOf: bounded.directory.appendingPathComponent("manifest.json")))
    try check(
      manifest.droppedEvents > 0 && manifest.savedFrames == 24 && manifest.skippedFrames == 1,
      "Retention limits did not report omissions")
    print("PASS bounded event/frame storage and explicit dropped-item counts")

    for _ in 0..<5 {
      let next = try DebugTraceStore(
        root: traces, runID: UUID(), kind: "fixture", version: "test", build: "1", options: .init())
      next.finish("done")
      try next.flush()
    }
    try check(DebugTraceStore.summaries(root: traces).count == 5, "Old traces were not pruned")
    print("PASS five-run retention")
  }
}
