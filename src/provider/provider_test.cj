package atelier.provider

import jsonvalue.*
import std.collection.*
import atelier.message.*
import atelier.event.EventStream

@Test
func chatRequest_extraField() {
    let extra = HashMap<String, JsonValue>()
    extra["reasoning_effort"] = JsonValue.String("high")
    let req = ChatRequest("m", ArrayList<Message>(), 0.7, 100, None, ArrayList(), extra)
    match (req.extra.get("reasoning_effort")) {
        case Some(JsonValue.String(s)) => @Expect(s, "high")
        case _ => @Fail("extra not carried")
    }
}

@Test
func chatRequest_withoutExtra_hasEmptyMap() {
    let req = ChatRequest("m", ArrayList<Message>(), 0.7, 100, None, ArrayList())
    @Expect(req.extra.size, 0)
}

class FakeProviderImpl <: Provider {
    public let provName: String
    public init(name: String) { this.provName = name }
    public func name(): String { this.provName }
    public func chat(req: ChatRequest): ChatResponse {
        ChatResponse(AssistantMessage(ContentList.ofText("fake"), "", "", StopReason.EndTurn, TokenUsage(0, 0), 0))
    }
    public func chatStreaming(req: ChatRequest): EventStream<ChatDelta, AssistantMessage> {
        let s = EventStream<ChatDelta, AssistantMessage>()
        s.emit(ChatDelta("fake", "", Some(StopReason.EndTurn)))
        s.setResult(AssistantMessage(ContentList.ofText("fake"), "", "", StopReason.EndTurn, TokenUsage(0, 0), 0))
        s
    }
}

class FakeFactory <: ProviderFactory {
    public func `type`(): String { "fake" }
    public func create(cfg: ProviderConfig): Provider { FakeProviderImpl(cfg.name) }
}

@Test
func providerConfig_fields() {
    let extra = HashMap<String, JsonValue>()
    extra["k"] = JsonValue.String("v")
    let cfg = ProviderConfig("f", "http://x", "key", ArrayList<String>(), extra)
    @Expect(cfg.name, "f")
    @Expect(cfg.baseURL, "http://x")
    @Expect(cfg.apiKey, "key")
    @Expect(cfg.headers.size, 0)
    match (cfg.extra.get("k")) {
        case Some(JsonValue.String(s)) => @Expect(s, "v")
        case _ => @Fail("extra not carried")
    }
}

@Test
func providerConfig_emptyHelper() {
    let cfg = ProviderConfig.empty("f")
    @Expect(cfg.name, "f")
    @Expect(cfg.baseURL, "")
    @Expect(cfg.extra.size, 0)
}

@Test
func providerFactory_typeAndCreate() {
    let f = FakeFactory()
    @Expect(f.`type`(), "fake")
    let cfg = ProviderConfig.empty("f")
    let p = f.create(cfg)
    @Expect(p.name(), "f")
}
