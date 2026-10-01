package atelier.agent

import std.collection.*
import atelier.message.*
import atelier.provider.*
import atelier.tool.*
import atelier.trust.*
import atelier.skill.*
import atelier.session.*
import atelier.event.EventStream
import jsonvalue.*

// 记录收到的 ChatRequest 的 provider：验证中间件转发/路由行为
class CaptureRequestProvider <: Provider {
    public var lastReq: ?ChatRequest = None
    public var callCount: Int64 = 0
    public func name(): String { "cap" }
    public func chat(req: ChatRequest): ChatResponse {
        this.lastReq = Some(req); this.callCount++
        ChatResponse(AssistantMessage(ContentList.ofText("ok"), "", "", StopReason.EndTurn, TokenUsage(0, 0), 0))
    }
    public func chatStreaming(req: ChatRequest): EventStream<ChatDelta, AssistantMessage> {
        this.lastReq = Some(req); this.callCount++
        let s = EventStream<ChatDelta, AssistantMessage>()
        let msg = AssistantMessage(ContentList.ofText("ok"), "", "", StopReason.EndTurn, TokenUsage(0, 0), 0)
        s.emit(ChatDelta("", "", Some(StopReason.EndTurn)))
        s.setResult(msg)
        s
    }
}

// 含图片的请求
func imageChatReq(model: String): ChatRequest {
    let blocks = ArrayList<ContentBlock>()
    blocks.add(ContentBlock.TextBlock("look"))
    blocks.add(ContentBlock.ImageBlock("aGVsbG8=", "image/png"))
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList(blocks), 0))
    ChatRequest(model, msgs, 0.7, 100, None, ArrayList<OpenAITool>())
}

// 纯文本请求
func textChatReq(model: String): ChatRequest {
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("hi"), 0))
    ChatRequest(model, msgs, 0.7, 100, None, ArrayList<OpenAITool>())
}

// 仅含 Files API 图片引用的请求（图片数据在服务端，本地只有 file_id）
func imageFileChatReq(model: String): ChatRequest {
    let blocks = ArrayList<ContentBlock>()
    blocks.add(ContentBlock.TextBlock("look"))
    blocks.add(ContentBlock.ImageFileBlock("file-api-abc123"))
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList(blocks), 0))
    ChatRequest(model, msgs, 0.7, 100, None, ArrayList<OpenAITool>())
}

// 带 detail 的图片请求
func imageDetailChatReq(model: String): ChatRequest {
    let blocks = ArrayList<ContentBlock>()
    blocks.add(ContentBlock.TextBlock("look"))
    blocks.add(ContentBlock.ImageBlock("aGVsbG8=", "image/png", "low"))
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList(blocks), 0))
    ChatRequest(model, msgs, 0.7, 100, None, ArrayList<OpenAITool>())
}

// ========== 中间件单测（直接 wrap） ==========

@Test
public func imageCapability_textOnly_passthrough() {
    let inner = CaptureRequestProvider()
    let mw = ImageCapabilityMiddleware(false)
    let wrapped = mw.wrap(inner)
    wrapped.chat(textChatReq("plain-model"))
    @Expect(inner.callCount, 1)
    match (inner.lastReq) {
        case Some(r) => @Expect(r.model, "plain-model")
        case None => @Fail("no request forwarded")
    }
}

@Test
public func imageCapability_supportsVision_passthrough() {
    let inner = CaptureRequestProvider()
    let mw = ImageCapabilityMiddleware(true)
    let wrapped = mw.wrap(inner)
    wrapped.chat(imageChatReq("vision-model"))
    @Expect(inner.callCount, 1)
    match (inner.lastReq) {
        case Some(r) =>
            @Expect(r.model, "vision-model")
            @Expect(hasImageBlockIn(r.messages), true)
        case None => @Fail("no request forwarded")
    }
}

@Test
public func imageCapability_noVision_throws() {
    let inner = CaptureRequestProvider()
    let mw = ImageCapabilityMiddleware(false)
    let wrapped = mw.wrap(inner)
    var caught = false
    try { wrapped.chat(imageChatReq("text-model")) } catch (e: Exception) { caught = true }
    @Expect(caught, true)
    @Expect(inner.callCount, 0)
}

@Test
public func imageCapability_noVision_routesToVisionModel() {
    let inner = CaptureRequestProvider()
    let mw = ImageCapabilityMiddleware(false, visionModel: Some("qwen-vl"))
    let wrapped = mw.wrap(inner)
    wrapped.chat(imageChatReq("text-model"))
    @Expect(inner.callCount, 1)
    match (inner.lastReq) {
        case Some(r) =>
            @Expect(r.model, "qwen-vl")
            @Expect(hasImageBlockIn(r.messages), true)
        case None => @Fail("no request forwarded")
    }
}

@Test
public func imageCapability_noVision_visionModelSameAsCurrent_throws() {
    let inner = CaptureRequestProvider()
    let mw = ImageCapabilityMiddleware(false, visionModel: Some("vl"))
    let wrapped = mw.wrap(inner)
    var caught = false
    try { wrapped.chat(imageChatReq("vl")) } catch (e: Exception) { caught = true }
    @Expect(caught, true)
    @Expect(inner.callCount, 0)
}

@Test
public func imageCapability_noVision_streamingThrows() {
    let inner = CaptureRequestProvider()
    let mw = ImageCapabilityMiddleware(false)
    let wrapped = mw.wrap(inner)
    var caught = false
    try { wrapped.chatStreaming(imageChatReq("text-model")) } catch (e: Exception) { caught = true }
    @Expect(caught, true)
    @Expect(inner.callCount, 0)
}

@Test
public func imageCapability_noVision_streamingRoutes() {
    let inner = CaptureRequestProvider()
    let mw = ImageCapabilityMiddleware(false, visionModel: Some("qwen-vl"))
    let wrapped = mw.wrap(inner)
    wrapped.chatStreaming(imageChatReq("text-model"))
    @Expect(inner.callCount, 1)
    match (inner.lastReq) {
        case Some(r) => @Expect(r.model, "qwen-vl")
        case None => @Fail("no request forwarded")
    }
}

// ========== runtime 集成：中间件注入 AgentRuntime 后图片请求自动路由 ==========

func makeCapabilityRuntime(provider: Provider, mws: ArrayList<ProviderMiddleware>): AgentRuntime {
    let toolReg = ToolRegistry()
    let trustMgr = TrustManager()
    let skillReg = SkillRegistry()
    let agentReg = AgentRegistry()
    let providerReg = ProviderRegistry()
    providerReg.register("default", provider)
    let store = MemorySessionStore()
    let mcpMgr = McpManager()
    testRuntime(subConfig(), provider, toolReg, store, trustMgr,
        skillReg, agentReg, providerReg, ArrayList<Hook>(),
        SessionEnvironment(), mcpMgr, middlewares: mws)
}

@Test
public func runtime_imageCapability_routesViaMiddleware() {
    let inner = CaptureRequestProvider()
    let mws = ArrayList<ProviderMiddleware>()
    mws.add(ImageCapabilityMiddleware(false, visionModel: Some("qwen-vl")))
    let runtime = makeCapabilityRuntime(inner, mws)
    let msgs = ArrayList<Message>()
    let blocks = ArrayList<ContentBlock>()
    blocks.add(ContentBlock.TextBlock("看图"))
    blocks.add(ContentBlock.ImageBlock("aGVsbG8=", "image/png"))
    msgs.add(UserMessage(ContentList(blocks), 0))
    runtime.chat(msgs).result()
    match (inner.lastReq) {
        case Some(r) => @Expect(r.model, "qwen-vl")
        case None => @Fail("provider never called")
    }
}

@Test
public func imageCapability_routes_keepsSystemPrompt() {
    let inner = CaptureRequestProvider()
    let mw = ImageCapabilityMiddleware(false, visionModel: Some("qwen-vl"))
    let wrapped = mw.wrap(inner)
    let base = imageChatReq("text-model")
    let req = ChatRequest(base.model, base.messages, base.temperature, base.maxTokens,
        base.reasoningEffort, base.tools, systemPrompt: "系统提示")
    wrapped.chat(req)
    match (inner.lastReq) {
        case Some(r) => @Expect(r.systemPrompt, "系统提示")
        case None => @Fail("no request forwarded")
    }
}

// ========== 图片形态：Files API 引用与 detail 也必须被判成"有图" ==========
// 漏判的后果不是少发一张图，而是**把图发给不支持视觉的模型**（闸门放行），
// 所以这里对每种形态都要求与内联图片同等的裁决。

@Test
public func imageCapability_fileRef_countsAsImage_routes() {
    let inner = CaptureRequestProvider()
    let mw = ImageCapabilityMiddleware(false, visionModel: Some("qwen-vl"))
    let wrapped = mw.wrap(inner)
    wrapped.chat(imageFileChatReq("text-model"))
    @Expect(inner.callCount, 1)
    match (inner.lastReq) {
        case Some(r) => @Expect(r.model, "qwen-vl")
        case None => @Fail("no request forwarded")
    }
}

@Test
public func imageCapability_fileRef_noVision_throws() {
    let inner = CaptureRequestProvider()
    let mw = ImageCapabilityMiddleware(false)
    let wrapped = mw.wrap(inner)
    var caught = false
    try { wrapped.chat(imageFileChatReq("text-model")) } catch (e: Exception) { caught = true }
    @Expect(caught, true)
    @Expect(inner.callCount, 0)
}

@Test
public func imageCapability_detailBlock_countsAsImage_routes() {
    let inner = CaptureRequestProvider()
    let mw = ImageCapabilityMiddleware(false, visionModel: Some("qwen-vl"))
    let wrapped = mw.wrap(inner)
    wrapped.chat(imageDetailChatReq("text-model"))
    @Expect(inner.callCount, 1)
    match (inner.lastReq) {
        case Some(r) => @Expect(r.model, "qwen-vl")
        case None => @Fail("no request forwarded")
    }
}

@Test
public func imageCapability_fileRef_supportsVision_passthrough() {
    let inner = CaptureRequestProvider()
    let mw = ImageCapabilityMiddleware(true)
    let wrapped = mw.wrap(inner)
    wrapped.chat(imageFileChatReq("vision-model"))
    match (inner.lastReq) {
        case Some(r) =>
            @Expect(r.model, "vision-model")
            @Expect(hasImageBlockIn(r.messages), true)
        case None => @Fail("no request forwarded")
    }
}

// 纯文本请求在任何形态判定变化后都不得被误判成有图
@Test
public func imageCapability_textOnly_notMistakenForImage() {
    let inner = CaptureRequestProvider()
    let mw = ImageCapabilityMiddleware(false)
    let wrapped = mw.wrap(inner)
    wrapped.chat(textChatReq("plain-model"))
    @Expect(inner.callCount, 1)
    match (inner.lastReq) {
        case Some(r) => @Expect(hasImageBlockIn(r.messages), false)
        case None => @Fail("no request forwarded")
    }
}
