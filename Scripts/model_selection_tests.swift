import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
  if !condition() { throw SubscriptionFailure.invalid(message) }
}
private func rejects(_ body: () throws -> Void) throws {
  var rejected = false
  do { try body() } catch { rejected = true }
  try require(rejected, "Expected rejection")
}
private func fixture(_ id: String, _ additions: [String: JSONValue] = [:]) -> JSONValue {
  .object(
    [
      "slug": .string(id), "display_name": .string(id.uppercased()), "visibility": .string("list"),
      "supported_reasoning_levels": .array([
        .object(["effort": .string("low")]), .object(["effort": .string("high")]),
      ]),
      "default_reasoning_level": .string("high"), "priority": .number(2),
      "input_modalities": .array([.string("text"), .string("image")]),
    ].merging(additions) { _, new in new })
}
private func completion(_ model: String, effort: String = "high") -> JSONValue {
  .object([
    "status": .string("completed"), "model": .string(model),
    "reasoning": .object(["effort": .string(effort)]),
    "output": .array([
      .object([
        "type": .string("function_call"), "call_id": .string("call-1"),
        "name": .string("phone_observe"), "arguments": .string("{}"),
      ])
    ]),
  ])
}
@main struct ModelSelectionTests {
  @MainActor static func main() async throws {
    let now = Date(timeIntervalSince1970: 1_000)
    var freshness = CatalogFreshness()
    try require(freshness.needsRefresh(at: now), "Cold launch should refresh")
    freshness.attempted(at: now)
    try require(!freshness.needsRefresh(at: now.addingTimeInterval(59)), "Failure retry storm")
    try require(freshness.needsRefresh(at: now.addingTimeInterval(60)), "Failure cannot retry")
    freshness.received(at: now.addingTimeInterval(1))
    try require(!freshness.needsRefresh(at: now.addingTimeInterval(300)), "Fresh catalog refetched")
    try require(freshness.needsRefresh(at: now.addingTimeInterval(301)), "Stale catalog retained")
    try require(freshness.needsRefresh(at: now.addingTimeInterval(-1)), "Clock rollback blocked refresh")
    freshness.reset()
    try require(freshness.needsRefresh(at: now), "Account change did not invalidate catalog")
    print("PASS cold launch, foreground freshness, failure backoff, clock rollback and account invalidation")

    let models = try ModelCatalog.parse(
      .object([
        "models": .array([
          fixture("fixture-vision", ["supported_in_api": .bool(false)]),
          fixture("hidden", ["visibility": .string("hide")]),
          fixture("text-only", ["input_modalities": .array([.string("text")])]),
          fixture("no-modalities", ["input_modalities": .array([])]),
          fixture("legacy", ["input_modalities": .null, "priority": .number(1)]),
          fixture("fixture-vision"),
        ])
      ]))
    try require(models.map(\.id) == ["legacy", "fixture-vision"], "Catalog eligibility/order")
    try rejects { _ = try ModelCatalog.parse(.object([:])) }
    print(
      "PASS catalog visibility, image support, subscription-only models, legacy modalities and duplicates"
    )

    let choice = ModelChoice(id: "fixture-vision", effort: "high")
    let config = try ModelCatalog.resolve(choice, in: models)
    try rejects { _ = try ModelCatalog.resolve(.initial, in: models) }
    try rejects { _ = try ModelCatalog.resolve(.init(id: choice.id, effort: "ultra"), in: models) }
    try rejects { _ = try ModelCatalog.resolve(.init(id: choice.id, effort: nil), in: models) }
    let simple = try ModelCatalog.parse(
      .object([
        "models": .array([
          fixture(
            "simple", ["supported_reasoning_levels": .array([]), "default_reasoning_level": .null])
        ])
      ]))
    let noEffort = try ModelCatalog.resolve(.init(id: "simple", effort: nil), in: simple)
    try require(
      noEffort.requestBody(input: [], tools: [])["reasoning"] == .null, "Unexpected reasoning")
    try require(ModelChoice.initial == .init(id: "gpt-6-astra", effort: "low"), "Default changed")
    print(
      "PASS effort validation, no silent model fallback, non-reasoning model and original default")

    let input: [JSONValue] = [
      .object([
        "role": .string("user"),
        "content": .array([
          .textContent("frame 1: 100x200"),
          .object([
            "type": .string("input_image"), "image_url": .string("data:image/jpeg;base64,fixture"),
            "detail": .string("original"),
          ]),
        ]),
      ]), .object(["type": .string("reasoning"), "encrypted_content": .string("opaque-fixture")]),
    ]
    let request = config.requestBody(input: input, tools: PhoneTools.definitions(readOnly: false))
    try require(
      request["model"].string == choice.id && request["reasoning"]["effort"].string == "high",
      "Wrong request model")
    let adapted = request["input"].array![0]["content"].array!
    try require(adapted[1]["detail"].string == "high", "Detail capability ignored")
    try require(
      adapted[1]["image_url"] == input[0]["content"].array![1]["image_url"], "Image changed")
    try require(adapted[0] == input[0]["content"].array![0], "Coordinates changed")
    try require(request["input"].array![1] == input[1], "Opaque history changed")
    try require(input[0]["content"].array![1]["detail"].string == "original", "History mutated")
    try require(
      ModelRunConfiguration.initial.prepare(.array(input)) == .array(input), "Original detail lost")
    print(
      "PASS dynamic requests and image detail adaptation preserve bytes, geometry and opaque history"
    )

    let collector = ModelResponseCollector(serverModel: nil, configuration: config)
    try require(
      tryValue { try collector.complete(completion(choice.id)).model } == choice.id, "Model receipt"
    )
    _ = try collector.complete(completion(choice.id + "-2026-09-22"))
    try rejects { _ = try collector.complete(completion("gpt-6-astra")) }
    try rejects { _ = try collector.complete(completion(choice.id + "-mini")) }
    try rejects { _ = try collector.complete(completion(choice.id + "-2026-arbitrary")) }
    try rejects { _ = try collector.complete(completion(choice.id, effort: "low")) }
    var decoder = ModelWireDecoder(serverModel: choice.id, configuration: config)
    let stream =
      "data: "
      + (try JSONValue.object([
        "type": .string("response.completed"), "response": completion(choice.id),
      ]).text()) + "\n\n"
    var turn: AgentModelTurn?
    for byte in stream.utf8 { if let completed = try decoder.feed(byte) { turn = completed } }
    try require(turn?.model == choice.id && turn?.effort == "high", "SSE selection lost")
    print("PASS alternate model SSE, dated aliases, wrong-model and wrong-effort rejection")

    var nextChoice = choice
    let frozen = try ModelCatalog.resolve(nextChoice, in: models)
    nextChoice = .initial
    try require(frozen.choice == choice, "Run config mutated")
    let snapshot = TaskSnapshot(
      id: UUID(), prompt: "fixture", phase: .completed,
      timeline: AgentTimeline(), result: "done", startedAt: Date(), updatedAt: Date(), model: frozen
    )
    let roundTrip = try JSONDecoder().decode(
      TaskSnapshot.self, from: JSONEncoder().encode(snapshot))
    try require(roundTrip.model == frozen, "Task model not persisted")
    var oldJSON = try JSONValue(snapshotData(snapshot)).object!
    oldJSON.removeValue(forKey: "model")
    let old = try JSONDecoder().decode(TaskSnapshot.self, from: JSONValue.object(oldJSON).data())
    try require(old.model == nil, "Old task records no longer load")
    print("PASS frozen task choice, persisted model and backward-compatible task records")

    let tiers = try ModelCatalog.parse(
      .object([
        "models": .array([
          fixture(
            "fast-current",
            [
              "service_tiers": .array([
                .object([
                  "id": .string("priority"), "name": .string("Fast"),
                  "description": .string("More credits"),
                ])
              ])
            ]),
          fixture("fast-alias", ["service_tiers": .array([.object(["id": .string("fast")])])]),
          fixture("fast-legacy", ["additional_speed_tiers": .array([.string("fast")])]),
          fixture("standard", ["default_service_tier": .string("priority")]),
        ])
      ]))
    for id in ["fast-current", "fast-alias", "fast-legacy"] {
      let fast = try ModelCatalog.resolve(.init(id: id, effort: "high", fastMode: true), in: tiers)
      let body = fast.requestBody(input: input, tools: [])
      try require(body["service_tier"].string == "priority", "Fast wire mapping")
      try require(
        fast.routingHint == "model=" + id + ";tier=priority", "Fast route differs from body")
      try require(
        body["model"].string == id && body["reasoning"]["effort"].string == "high",
        "Fast changed model/effort")
      let saved = try JSONDecoder().decode(
        ModelRunConfiguration.self, from: JSONEncoder().encode(fast))
      try require(saved == fast && saved.choice.fastMode, "Fast lost across save/resume")
    }
    try rejects {
      _ = try ModelCatalog.resolve(.init(id: "standard", effort: "high", fastMode: true), in: tiers)
    }
    try rejects {
      _ = try ModelCatalog.resolve(.init(id: choice.id, effort: "high", fastMode: true), in: models)
    }
    let standard = try ModelCatalog.resolve(.init(id: "standard", effort: "high"), in: tiers)
    try require(standard.routingHint == "model=standard", "Standard route enables Fast")
    let invalidHeader = ModelRunConfiguration(
      choice: .init(id: "bad;\\r\\nheader", effort: nil, fastMode: true), name: "invalid",
      supportsOriginalImages: false)
    try require(invalidHeader.routingHint == nil, "Unsafe catalog ID entered header")
    try require(
      standard.requestBody(input: [], tools: [])["service_tier"] == .null,
      "Catalog default silently enabled Fast")
    let oldChoice = try JSONDecoder().decode(
      ModelChoice.self, from: Data(#"{"id":"fixture-vision","effort":"high"}"#.utf8))
    try require(oldChoice == choice && !oldChoice.fastMode, "Legacy preference became Fast")
    var legacyConfig = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(config))
      .object!
    var legacyChoice = legacyConfig["choice"]!.object!
    legacyChoice.removeValue(forKey: "fastMode")
    legacyConfig["choice"] = .object(legacyChoice)
    let decodedLegacy = try JSONDecoder().decode(
      ModelRunConfiguration.self, from: JSONValue.object(legacyConfig).data())
    try require(decodedLegacy == config, "Old frozen config cannot resume")
    print(
      "PASS Fast capability/current and legacy catalogs, priority wire mapping, default off and persisted configuration"
    )

    let fastConfig = try ModelCatalog.resolve(
      .init(id: "fast-current", effort: "high", fastMode: true), in: tiers)
    var fastCollector = ModelResponseCollector(serverModel: nil, configuration: fastConfig)
    _ = try fastCollector.consume([
      "type": "response.created",
      "response": ["model": "fast-current", "service_tier": "priority"],
    ])
    let missing = try fastCollector.complete(completion("fast-current"))
    try require(missing.serviceTier == nil, "Created event was mistaken for actual tier")
    for tier in ["priority", "fast", "default"] {
      var receipt = completion("fast-current").object!
      receipt["service_tier"] = .string(tier)
      var streamDecoder = ModelWireDecoder(serverModel: nil, configuration: fastConfig)
      let data =
        "data: "
        + (try JSONValue.object([
          "type": .string("response.completed"), "response": .object(receipt),
        ]).text()) + "\n\n"
      var result: AgentModelTurn?
      for byte in data.utf8 { if let turn = try streamDecoder.feed(byte) { result = turn } }
      try require(result?.serviceTier == tier, "Completion service tier lost")
      let message = fastConfig.serviceTierStatus(actual: result?.serviceTier)!
      try require(message.contains(tier == "default" ? "未确认" : "已确认"), "Incorrect tier claim")
    }
    try require(
      fastConfig.serviceTierStatus(actual: nil)!.contains("未返回"), "Missing receipt claimed Fast")
    try require(config.serviceTierStatus(actual: nil) == nil, "Standard falsely claims Fast")
    print("PASS SSE actual tier, server downgrade and absent receipt remain distinct")

  }
  static func tryValue<T>(_ body: () throws -> T) -> T? { try? body() }
  static func snapshotData(_ value: TaskSnapshot) throws -> Any {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
  }
}
