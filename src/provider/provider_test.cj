package atelier.provider

import jsonvalue.*
import std.collection.*
import stdx.net.http.*
import atelier.message.*
import atelier.event.EventStream
import atelier.util.toJsonString

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
func openaiRequest_extraKeysInJson() {
    let extra = HashMap<String, JsonValue>()
    let rf = HashMap<String, JsonValue>()
    rf["type"] = JsonValue.String("json_object")
    extra["response_format"] = JsonValue.Map(rf)
    extra["top_p"] = JsonValue.Number(0.9)
    let req = OpenAIRequest("m", ArrayList<OpenAIMessage>(), false, 0.7, 100,
        None, ArrayList<OpenAITool>(), extra)
    let json = toJsonString(req)
    @Expect(json.contains("response_format"), true)
    @Expect(json.contains("json_object"), true)
    @Expect(json.contains("top_p"), true)
}

@Test
func openaiRequest_extraReservedKeysIgnored() {
    let extra = HashMap<String, JsonValue>()
    extra["model"] = JsonValue.String("evil-model")
    extra["temperature"] = JsonValue.Number(9.9)
    extra["max_tokens"] = JsonValue.Number(Float64(999))
    let req = OpenAIRequest("real-model", ArrayList<OpenAIMessage>(), false, 0.7, 100,
        None, ArrayList<OpenAITool>(), extra)
    let json = toJsonString(req)
    @Expect(json.contains("evil-model"), false)
    @Expect(json.contains("9.9"), false)
    @Expect(json.contains("real-model"), true)
}

@Test
func openaiBuildRequest_passesExtra() {
    let extra = HashMap<String, JsonValue>()
    extra["top_p"] = JsonValue.Number(0.9)
    let req = ChatRequest("m", ArrayList<Message>(), 0.7, 100, None,
        ArrayList<OpenAITool>(), extra)
    let oai = buildRequest(req, false)
    let json = toJsonString(oai)
    @Expect(json.contains("top_p"), true)
    @Expect(json.contains("0.9"), true)
}

@Test
func anthropicRequest_extraKeysInBody() {
    let extra = HashMap<String, JsonValue>()
    extra["metadata"] = JsonValue.Map(HashMap<String, JsonValue>())
    let stops = ArrayList<JsonValue>()
    stops.add(JsonValue.String("END"))
    extra["stop_sequences"] = JsonValue.Array(stops)
    let req = ChatRequest("m", ArrayList<Message>(), 0.7, 100, None,
        ArrayList<OpenAITool>(), extra)
    let body = buildAnthropicRequest(req, false)
    @Expect(body.contains("metadata"), true)
    @Expect(body.contains("stop_sequences"), true)
    @Expect(body.contains("END"), true)
}

@Test
func anthropicRequest_extraReservedIgnored() {
    let extra = HashMap<String, JsonValue>()
    extra["model"] = JsonValue.String("evil-model")
    extra["max_tokens"] = JsonValue.Number(Float64(999))
    let req = ChatRequest("real-model", ArrayList<Message>(), 0.7, 100, None,
        ArrayList<OpenAITool>(), extra)
    let body = buildAnthropicRequest(req, false)
    @Expect(body.contains("evil-model"), false)
    @Expect(body.contains("999"), false)
    @Expect(body.contains("real-model"), true)
}

@Test
func ollamaRequest_extraKeysInBody() {
    let extra = HashMap<String, JsonValue>()
    extra["keep_alive"] = JsonValue.String("5m")
    extra["num_ctx"] = JsonValue.Number(Float64(4096))
    let req = ChatRequest("m", ArrayList<Message>(), 0.7, 100, None,
        ArrayList<OpenAITool>(), extra)
    let body = buildOllamaRequest(req, false)
    @Expect(body.contains("keep_alive"), true)
    @Expect(body.contains("num_ctx"), true)
    @Expect(body.contains("5m"), true)
}

@Test
func ollamaRequest_extraReservedIgnored() {
    let extra = HashMap<String, JsonValue>()
    extra["model"] = JsonValue.String("evil-model")
    extra["stream"] = JsonValue.Boolean(false)
    let req = ChatRequest("real-model", ArrayList<Message>(), 0.7, 100, None,
        ArrayList<OpenAITool>(), extra)
    let body = buildOllamaRequest(req, true)
    @Expect(body.contains("evil-model"), false)
    @Expect(body.contains("real-model"), true)
    @Expect(body.contains("false"), false)
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
