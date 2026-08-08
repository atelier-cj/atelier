package atelier.provider

import jsonvalue.*
import std.collection.*
import stdx.net.http.*
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
    let cfg = ProviderConfig("fake", "f", "http://x", "key", ArrayList<String>(), extra)
    @Expect(cfg.`type`, "fake")
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
    let cfg = ProviderConfig.empty("fake", "f")
    @Expect(cfg.`type`, "fake")
    @Expect(cfg.name, "f")
    @Expect(cfg.baseURL, "")
    @Expect(cfg.extra.size, 0)
}

@Test
func providerFactory_typeAndCreate() {
    let f = FakeFactory()
    @Expect(f.`type`(), "fake")
    let cfg = ProviderConfig.empty("fake", "f")
    let p = f.create(cfg)
    @Expect(p.name(), "f")
}

@Test
func registry_factoryRegisterAndCreate() {
    let reg = ProviderRegistry()
    reg.registerFactory(FakeFactory())
    match (reg.getFactory("fake")) {
        case Some(_) => ()
        case None => @Fail("factory not registered")
    }
    let cfg = ProviderConfig.empty("fake", "f")
    let p = reg.create(cfg)
    @Expect(p.name(), "f")
}

@Test
func registry_createUnknownType_throws() {
    let reg = ProviderRegistry()
    let cfg = ProviderConfig.empty("unknown", "x")
    var caught = false
    try { reg.create(cfg) } catch (e: Exception) { caught = true }
    @Expect(caught, true)
}

@Test
func registry_defaultHasBuiltinFactories() {
    let reg = ProviderRegistry.default()
    match (reg.getFactory("openai")) { case Some(_) => (); case None => @Fail("no openai factory") }
    match (reg.getFactory("anthropic")) { case Some(_) => (); case None => @Fail("no anthropic factory") }
    match (reg.getFactory("ollama")) { case Some(_) => (); case None => @Fail("no ollama factory") }
}

@Test
func builtinFactory_openai_create() {
    let f = OpenAIFactory()
    @Expect(f.`type`(), "openai")
    let cfg = ProviderConfig("openai", "my-openai", "http://localhost:8089", "key", ArrayList<String>(), HashMap<String, JsonValue>())
    let p = f.create(cfg)
    @Expect(p.name(), "my-openai")
}

@Test
func builtinFactory_anthropic_create() {
    let f = AnthropicFactory()
    @Expect(f.`type`(), "anthropic")
    let cfg = ProviderConfig.empty("anthropic", "my-anthropic")
    let p = f.create(cfg)
    @Expect(p.name(), "my-anthropic")
}

@Test
func builtinFactory_ollama_create() {
    let f = OllamaFactory()
    @Expect(f.`type`(), "ollama")
    let cfg = ProviderConfig.empty("ollama", "my-ollama")
    let p = f.create(cfg)
    @Expect(p.name(), "my-ollama")
}

@Test
func applyExtraHeaders_parsesNameValue() {
    let headers = ArrayList<String>()
    headers.add("X-Custom:  value1  ")
    headers.add("X-Other:value2")
    headers.add("malformed-header-without-colon")
    let b = HttpRequestBuilder()
    b.url("http://localhost:1/chat/completions")
    applyExtraHeaders(b, headers)
    b.post()
    let req = b.build()
    match (req.headers.getFirst("X-Custom")) {
        case Some(v) => @Expect(v, "value1")
        case None => @Fail("X-Custom not applied")
    }
    match (req.headers.getFirst("X-Other")) {
        case Some(v) => @Expect(v, "value2")
        case None => @Fail("X-Other not applied")
    }
    match (req.headers.getFirst("malformed-header-without-colon")) {
        case Some(_) => @Fail("malformed header should be skipped")
        case None => ()
    }
}
