package server

import stdx.net.http.*
import std.collection.*
import std.core.Duration
import atelier.agent.*
import atelier.message.*
import atelier.provider.*
import atelier.tool.*
import atelier.session.*
import atelier.session.{exportToJsonl, exportToHtml}
import atelier.skill.*
import atelier.trust.*
import atelier.util.{toJsonString, fromJsonString}
import stdx.encoding.json.stream.{JsonSerializable, JsonDeserializable}
import stdx.log.*
import std.collection.concurrent.*
import atelier.interaction.*

/**
 * 一条待答提问：请求本体 + 答复队列。
 *
 * 请求本体要留着：回传的答复得按字段类型包装（bool/multi_select），还要过 validateAnswer ——
 * 两件事都需要知道"当初问的是什么"。
 */
class PendingAsk {
    let req: UserRequest
    let queue: LinkedBlockingQueue<UserAnswer>

    init(req: UserRequest) {
        this.req = req
        this.queue = LinkedBlockingQueue<UserAnswer>(1)
    }
}

public class AtelierHttpHandler {
    // 装配束：组件一次装配，handler 只是把它接到 HTTP 上
    private let spec: HarnessSpec
    // 待答提问：key = UserRequest.id（确定性），答复按 id 精确投递 —— 并发请求下不能"投给任意一个"
    let pendingAsks = HashMap<String, PendingAsk>()

    public init(spec: HarnessSpec) {
        this.spec = spec
    }

    /** 本次装配（宿主想换组件时先派生新的装配束，再建 handler） */
    public func components(): HarnessSpec { this.spec }

    public func registerRoutes(distributor: HttpRequestDistributor): Unit {
        let h = this
        distributor.register("/agent/config", { ctx => h.handleAgentConfig(ctx) })
        distributor.register("/agent/configs", { ctx => h.handleAgentConfigs(ctx) })
        distributor.register("/agent/run", { ctx => h.handleAgentRun(ctx) })
        distributor.register("/agent/stream", { ctx => h.handleAgentStream(ctx) })
        distributor.register("/agent/input", { ctx => h.handleAgentInput(ctx) })
        distributor.register("/session/save", { ctx => h.handleSessionSave(ctx) })
        distributor.register("/session/load", { ctx => h.handleSessionLoad(ctx) })
        distributor.register("/session/fork", { ctx => h.handleSessionFork(ctx) })
        distributor.register("/session/export", { ctx => h.handleSessionExport(ctx) })
        distributor.register("/sessions", { ctx => h.handleSessionList(ctx) })
        distributor.register("/trust", { ctx => h.handleTrust(ctx) })
        distributor.register("/health", { ctx => h.handleHealth(ctx) })
        distributor.register("/v1/chat/completions", { ctx => h.handleV1Chat(ctx) })
        // AG-UI 对外端点（公开协议）：与其余路由共用同一份装配束
        let agUi = AgUiHandler(this.spec)
        distributor.register("/ag-ui/agent", { ctx => agUi.handleAgent(ctx) })
    }

    private func handleAgentConfig(ctx: HttpContext): Unit {
        match (ctx.request.method) {
            case "GET" =>
                let agents = this.spec.agents.list()
                let names = ArrayList<String>()
                for ((k, _) in agents) { names.add(k) }
                jsonResponse(ctx, 200, toJsonString(AgentListResponse(names)))
            case "POST" =>
                let dto = try { readJson<AgentConfigDTO>(ctx) } catch (_) {
                    jsonResponse(ctx, 400, toJsonString(ErrorResponse("invalid JSON"))); return
                }
                let cfg = configFromDTO(dto)
                try {
                    this.spec.agents.create(dto.name, cfg)
                    jsonResponse(ctx, 201, toJsonString(StatusResponse("created")))
                } catch (e: Exception) {
                    jsonResponse(ctx, 409, toJsonString(ErrorResponse(e.message)))
                }
            case "DELETE" =>
                let dto = try { readJson<DeleteAgentDTO>(ctx) } catch (_) {
                    jsonResponse(ctx, 400, toJsonString(ErrorResponse("invalid JSON"))); return
                }
                let deleted = this.spec.agents.delete(dto.name)
                if (deleted) {
                    jsonResponse(ctx, 200, toJsonString(StatusResponse("deleted")))
                } else {
                    jsonResponse(ctx, 404, toJsonString(ErrorResponse("agent not found: " + dto.name)))
                }
            case _ => jsonResponse(ctx, 405, toJsonString(ErrorResponse("method not allowed")))
        }
    }

    private func handleAgentConfigs(ctx: HttpContext): Unit {
        let agents = this.spec.agents.list()
        let items = ArrayList<AgentItem>()
        for ((k, v) in agents) {
            items.add(AgentItem(k, v.model, v.systemPrompt))
        }
        jsonResponse(ctx, 200, toJsonString(AgentConfigListResponse(items)))
    }

    private func handleAgentRun(ctx: HttpContext): Unit {
        let dto = try { readJson<ChatRequestDTO>(ctx) } catch (_) {
            jsonResponse(ctx, 400, toJsonString(ErrorResponse("invalid JSON"))); return
        }
        let agentCfg = match (this.spec.agents.get(dto.agent)) {
            case Some(c) => c
            case None => jsonResponse(ctx, 404, toJsonString(ErrorResponse("agent not found"))); return
        }
        let msgs = ArrayList<Message>()
        for (m in dto.messages) {
            if (m.role == "user") { msgs.add(UserMessage(ContentList.ofText(m.content), 0)) }
        }
        // 一次性端点没有回传通道：不带 ask（提问即取消，工具会如实回报"没问到"）
        let runtime = AgentRuntime(this.spec, agentCfg)
        // sessionId 透传：请求带 sessionId 时事件与请求一致（否则随机 ulid）
        let eventStream = match (dto.sessionId) {
            case Some(sid) => runtime.chatWithSessionId(sid, msgs, SessionEnvironment())
            case None => runtime.chat(msgs)
        }
        let msgsResult = eventStream.result()
        let lastText = lastAssistantText(msgsResult)
        jsonResponse(ctx, 200, toJsonString(ContentResponse(lastText)))
    }

    private func handleAgentStream(ctx: HttpContext): Unit {
        let body = readBody(ctx)
        let dto = try { fromJsonString<ChatRequestDTO>(body) } catch (_) {
            jsonResponse(ctx, 400, toJsonString(ErrorResponse("invalid JSON"))); return
        }
        let agentCfg = match (this.spec.agents.get(dto.agent)) {
            case Some(c) => c
            case None => jsonResponse(ctx, 404, toJsonString(ErrorResponse("agent not found"))); return
        }
        let msgs = ArrayList<Message>()
        for (m in dto.messages) {
            if (m.role == "user") { msgs.add(UserMessage(ContentList.ofText(m.content), 0)) }
        }

        let b = ctx.responseBuilder
        b.status(UInt16(200))
        b.header("content-type", "text/event-stream")
        b.header("cache-control", "no-cache")
        b.header("connection", "keep-alive")
        b.header("transfer-encoding", "chunked")

        let writer = HttpResponseWriter(ctx)
        let log = getGlobalLogger([("name", "SSE")])
        // 提问通道：整条 UserRequest 推给客户端，答复由 /agent/input 按同一个 id 送回。
        // 回合线程在这里阻塞等人（人思考多久都不算卡死），答复到达才继续。
        let askFn: AskFn = { req =>
            let frame = "data: " + toJsonString(UserRequestFrame(req)) + "\n\n"
            // 写失败则客户端永远看不到提问，而本线程随后阻塞在 queue.remove() 上——必须留痕
            try { writer.write(frame.toArray()) } catch (e: Exception) {
                eprintln("[atelier] SSE user_request write failed: ${e.toString()}")
            }
            let pending = PendingAsk(req)
            this.pendingAsks[req.id] = pending
            log.info("user request waiting: ${req.id}", Array<Attr>())
            let ans = pending.queue.remove()
            this.pendingAsks.remove(req.id)
            log.info("user request answered: ${req.id}", Array<Attr>())
            ans
        }
        let runtime = AgentRuntime(this.spec.withAsk(askFn), agentCfg)
        // sessionId 透传：请求带 sessionId 时事件与请求一致（否则随机 ulid）
        let eventStream = match (dto.sessionId) {
            case Some(sid) => runtime.chatWithSessionId(sid, msgs, SessionEnvironment())
            case None => runtime.chat(msgs)
        }
        try {
            doSSEStream(ctx, eventStream, writer)
        } catch (e: Exception) {
            log.error("sse error: ${e.message}", Array<Attr>())
        }
    }

    private func doSSEStream(ctx: HttpContext, eventStream: LoopEventStream, writer: HttpResponseWriter): Unit {
        var done = false
        while (!done) {
            match (eventStream.receive(30 * Duration.second)) {
                case Some(ev) =>
                    let sseData = sseFromEvent(ev)
                    writer.write(sseData.toArray())
                    match (ev) {
                        case ae: AgentEndEvent => done = true
                        case te: TurnEndEvent =>
                            match (te.message.stopReason) {
                                case StopReason.Error => done = true
                                case _ => ()
                            }
                        case _ => ()
                    }
                case None => done = true
            }
        }
    }

    private func handleTrust(ctx: HttpContext): Unit {
        let dto = try { readJson<TrustRequestDTO>(ctx) } catch (_) {
            jsonResponse(ctx, 400, toJsonString(ErrorResponse("invalid JSON"))); return
        }
        if (dto.action == "set") {
            let trust = if (dto.trust == "trusted") { TrustState.Trusted }
            else if (dto.trust == "untrusted") { TrustState.Untrusted }
            else { jsonResponse(ctx, 400, toJsonString(ErrorResponse("trust must be 'trusted' or 'untrusted'"))); return }
            this.spec.trust.setTrust(dto.path, trust)
            jsonResponse(ctx, 200, toJsonString(TrustResponse(dto.path, dto.trust, "ok")))
        } else if (dto.action == "reset") {
            this.spec.trust.setTrust(dto.path, TrustState.Undecided)
            jsonResponse(ctx, 200, toJsonString(TrustResponse(dto.path, "undecided", "reset")))
        } else {
            let state = this.spec.trust.getEffectiveTrust(dto.path)
            let name = match (state) {
                case TrustState.Trusted => "trusted"
                case TrustState.Untrusted => "untrusted"
                case _ => "undecided"
            }
            jsonResponse(ctx, 200, toJsonString(TrustResponse(dto.path, name, "")))
        }
    }

    private func handleSessionList(ctx: HttpContext): Unit {
        let sessions = try { this.spec.store.list() } catch (_) {
            jsonResponse(ctx, 500, toJsonString(ErrorResponse("failed to list sessions"))); return
        }
        let items = ArrayList<SessionItem>()
        for (s in sessions) { items.add(SessionItem(s.id, s.model)) }
        jsonResponse(ctx, 200, toJsonString(SessionListResponse(items)))
    }

    private func handleSessionFork(ctx: HttpContext): Unit {
        let dto = try { readJson<SessionForkDTO>(ctx) } catch (_) {
            jsonResponse(ctx, 400, toJsonString(ErrorResponse("invalid JSON"))); return
        }
        try {
            let fork = this.spec.store.fork(dto.sourceId, dto.leafId)
            jsonResponse(ctx, 200, toJsonString(ForkResponse("forked", fork.entries.size)))
        } catch (e: Exception) {
            jsonResponse(ctx, 500, toJsonString(ErrorResponse(e.message)))
        }
    }

    private func handleSessionSave(ctx: HttpContext): Unit {
        let dto = try { readJson<SessionSaveDTO>(ctx) } catch (_) {
            jsonResponse(ctx, 400, toJsonString(ErrorResponse("invalid JSON"))); return
        }
        if (dto.sessionId == "") { jsonResponse(ctx, 400, toJsonString(ErrorResponse("missing sessionId"))); return }
        try {
            let header = if (dto.header != "") { fromJsonString<SessionHeader>(dto.header) } else { SessionHeader(0, "", 0, 0, "", "", "", None) }
            let msgs = ArrayList<Message>()
            for (m in dto.messages) {
                if (m.role == "user") { msgs.add(UserMessage(ContentList.ofText(m.content), 0)) }
                else if (m.role == "assistant") { msgs.add(AssistantMessage(ContentList.ofText(m.content), "", "", StopReason.EndTurn, TokenUsage(0, 0), 0)) }
            }
            this.spec.store.save(dto.sessionId, header, msgs)
            jsonResponse(ctx, 200, toJsonString(StatusResponse("saved")))
        } catch (e: Exception) {
            jsonResponse(ctx, 500, toJsonString(ErrorResponse(e.message)))
        }
    }

    private func handleSessionLoad(ctx: HttpContext): Unit {
        let dto = try { readJson<SessionLoadDTO>(ctx) } catch (_) {
            jsonResponse(ctx, 400, toJsonString(ErrorResponse("invalid JSON"))); return
        }
        if (dto.sessionId == "") { jsonResponse(ctx, 400, toJsonString(ErrorResponse("missing sessionId"))); return }
        try {
            let msgs = this.spec.store.load(dto.sessionId)
            let parts = ArrayList<String>()
            for (m in msgs) {
                match (m) {
                    case um: UserMessage => parts.add("user: " + toText(um.content))
                    case am: AssistantMessage => parts.add("assistant: " + toText(am.content))
                    case _ => ()
                }
            }
            var text = ""
            for (p in parts) {
                if (text != "") { text = text + "\n" }
                text = text + p
            }
            jsonResponse(ctx, 200, toJsonString(ContentResponse(text)))
        } catch (_) {
            jsonResponse(ctx, 404, toJsonString(ErrorResponse("session not found")))
        }
    }

    private func handleSessionExport(ctx: HttpContext): Unit {
        let dto = try { readJson<SessionExportDTO>(ctx) } catch (_) {
            jsonResponse(ctx, 400, toJsonString(ErrorResponse("invalid JSON"))); return
        }
        if (dto.sessionId == "") { jsonResponse(ctx, 400, toJsonString(ErrorResponse("missing sessionId"))); return }
        try {
            let msgs = this.spec.store.load(dto.sessionId)
            let text = if (dto.format == "html") { exportToHtml(msgs) } else { exportToJsonl(msgs) }
            let contentType = if (dto.format == "html") { "text/html" } else { "application/jsonl" }
            let b = ctx.responseBuilder
            b.status(UInt16(200))
            b.header("content-type", contentType)
            b.header("content-disposition", "attachment; filename=\"" + dto.sessionId + "." + dto.format + "\"")
            b.body(text)
        } catch (_) {
            jsonResponse(ctx, 404, toJsonString(ErrorResponse("session not found")))
        }
    }

    private func handleHealth(ctx: HttpContext): Unit {
        jsonResponse(ctx, 200, toJsonString(StatusResponse("ok")))
    }

    private func handleV1Chat(ctx: HttpContext): Unit {
        let dto = try { readJson<ChatCompletionRequest>(ctx) } catch (_) {
            jsonResponse(ctx, 400, toJsonString(ErrorResponse("invalid JSON"))); return
        }

        // Resolve agent: try model name as agent name, else use default
        let agentName = if (this.spec.agents.has(dto.model)) { dto.model } else { "default" }
        let agentCfg = match (this.spec.agents.get(agentName)) {
            case Some(c) => c
            case None =>
                jsonResponse(ctx, 404, toJsonString(ErrorResponse("model not found: " + dto.model)))
                return
        }

        // Convert messages
        let msgs = ArrayList<Message>()
        for (m in dto.messages) {
            match (m.role) {
                case "user" => msgs.add(UserMessage(ContentList.ofText(m.content), 0))
                case "assistant" => msgs.add(AssistantMessage(ContentList.ofText(m.content), "", "", StopReason.EndTurn, TokenUsage(0, 0), 0))
                case "system" =>
                    // Prepend system message as user message with system prefix
                    msgs.add(UserMessage(ContentList.ofText("[System]: " + m.content), 0))
                case _ => ()
            }
        }

        let runtime = AgentRuntime(this.spec, agentCfg)

        if (dto.stream) {
            doV1ChatStream(ctx, runtime, msgs, dto.model, dto.sessionId)
        } else {
            doV1ChatSync(ctx, runtime, msgs, dto.model, dto.sessionId)
        }
    }

    private func doV1ChatSync(ctx: HttpContext, runtime: AgentRuntime,
        msgs: ArrayList<Message>, model: String, sessionId: Option<String>): Unit {
        // sessionId 透传：请求带 sessionId 时事件与请求一致（否则随机 ulid）
        let eventStream = match (sessionId) {
            case Some(sid) => runtime.chatWithSessionId(sid, msgs, SessionEnvironment())
            case None => runtime.chat(msgs)
        }
        let result = eventStream.result()
        let lastText = lastAssistantText(result)
        let resp = ChatCompletionResponse(
            "chatcmpl-" + Int64(0).toString(),
            "chat.completion",
            Int64(0),
            model,
            ArrayList<Choice>([Choice(0,
                ChatCompletionResponseMessage("assistant", lastText),
                "stop")]),
            Usage(0, 0, 0))
        jsonResponse(ctx, 200, toJsonString(resp))
    }

    private func doV1ChatStream(ctx: HttpContext, runtime: AgentRuntime,
        msgs: ArrayList<Message>, model: String, sessionId: Option<String>): Unit {
        let b = ctx.responseBuilder
        b.status(UInt16(200))
        b.header("content-type", "text/event-stream")
        b.header("cache-control", "no-cache")
        b.header("connection", "keep-alive")
        b.header("transfer-encoding", "chunked")

        let writer = HttpResponseWriter(ctx)
        // sessionId 透传：请求带 sessionId 时事件与请求一致（否则随机 ulid）
        let eventStream = match (sessionId) {
            case Some(sid) => runtime.chatWithSessionId(sid, msgs, SessionEnvironment())
            case None => runtime.chat(msgs)
        }
        let id = "chatcmpl-" + Int64(0).toString()
        var done = false
        try {
            while (!done) {
                match (eventStream.receive(30 * Duration.second)) {
                    case Some(ev) =>
                        match (ev) {
                            case upd: MessageUpdateEvent =>
                                if (upd.delta != "") {
                                    let chunk = "{\"id\":\"" + id + "\",\"object\":\"chat.completion.chunk\",\"created\":0,\"model\":\"" + model + "\",\"choices\":[{\"delta\":{\"content\":\"" + escapeJson(upd.delta) + "\"},\"index\":0}]}"
                                    writer.write(("data: " + chunk + "\n\n").toArray())
                                }
                            case _: AgentEndEvent =>
                                let finish = "{\"id\":\"" + id + "\",\"object\":\"chat.completion.chunk\",\"created\":0,\"model\":\"" + model + "\",\"choices\":[{\"delta\":{},\"index\":0,\"finish_reason\":\"stop\"}]}"
                                writer.write(("data: " + finish + "\n\n").toArray())
                                writer.write("data: [DONE]\n\n".toArray())
                                done = true
                            case _ => ()
                        }
                    case None => done = true
                }
            }
        } catch (e: Exception) {
            // v1 流式：写帧/消费事件失败被整个吞掉会表现为「响应流莫名中断且无 [DONE]」
            eprintln("[atelier] v1 chat stream aborted: ${e.toString()}")
        }
    }

    private func handleAgentInput(ctx: HttpContext): Unit {
        let dto = try { readJson<SessionInputDTO>(ctx) } catch (_) {
            jsonResponse(ctx, 400, toJsonString(ErrorResponse("invalid JSON"))); return
        }
        if (dto.requestId == "") {
            jsonResponse(ctx, 400, toJsonString(ErrorResponse("missing requestId"))); return
        }
        let pending = match (this.pendingAsks.get(dto.requestId)) {
            case Some(p) => p
            case None =>
                // 对不上任何待答提问：多半是 id 打错或提问已结束。回 404 而不是静默 200 ——
                // 静默成功会让调用方以为答复已生效，而回合仍在原地等人
                jsonResponse(ctx, 404,
                    toJsonString(ErrorResponse("no pending request: " + dto.requestId))); return
        }
        let ans = dto.toAnswer(pending.req)
        match (validateAnswer(pending.req, ans)) {
            case Some(err) =>
                jsonResponse(ctx, 400, toJsonString(ErrorResponse("invalid answer: " + err))); return
            case None => ()
        }
        // 投递失败 = 答复丢失，而等待方仍阻塞在 queue.remove() 上——必须留痕
        try { pending.queue.add(ans) } catch (e: Exception) {
            eprintln("[atelier] pending answer enqueue failed (answer dropped): ${e.toString()}")
        }
        jsonResponse(ctx, 200, toJsonString(StatusResponse("ok")))
    }

}

func jsonResponse(ctx: HttpContext, code: Int64, body: String): Unit {
    let b = ctx.responseBuilder
    b.status(UInt16(code))
    b.header("content-type", "application/json")
    b.body(body)
}

func json<T>(ctx: HttpContext, code: Int64, obj: T): Unit where T <: JsonSerializable {
    let b = ctx.responseBuilder
    b.status(UInt16(code))
    b.header("content-type", "application/json")
    b.body(toJsonString(obj))
}

func readJson<T>(ctx: HttpContext): T where T <: JsonDeserializable<T> {
    fromJsonString<T>(readBody(ctx))
}

func readBody(ctx: HttpContext): String {
    let buf = Array<Byte>(4096, repeat: 0)
    let all = ArrayList<Byte>()
    let input = ctx.request.body
    while (true) {
        let n: Int64
        // 读取失败即中断：请求体被截断后仍按「完整报文」解析，必须留痕
        try { n = input.read(buf) } catch (e: Exception) {
            eprintln("[atelier] HTTP request body read failed (body truncated): ${e.toString()}")
            break
        }
        if (n <= 0) { break }
        for (i in 0..n) { all.add(buf[Int64(i)]) }
    }
    let raw = Array<Byte>(all.size, repeat: 0)
    for (i in 0..all.size) { raw[i] = all[i] }
    String.fromUtf8(raw)
}

func escapeJson(s: String): String {
    var r = s.replace("\\", "\\\\")
    r = r.replace("\"", "\\\"")
    r = r.replace("\n", "\\n")
    r
}

func sseFromEvent(ev: AgentEvent): String {
    let json = match (ev) {
        case e: AgentStartEvent =>
            "{\"type\":\"agent_start\",\"sessionId\":\"" + escapeJson(e.sessionId) + "\"}"
        case e: AgentEndEvent =>
            "{\"type\":\"agent_end\"}"
        case _: TurnStartEvent =>
            "{\"type\":\"turn_start\"}"
        case e: TurnEndEvent =>
            let stopStr = match (e.message.stopReason) {
                case StopReason.ToolUse => "\"tool_use\""
                case StopReason.Length => "\"length\""
                case StopReason.Error => "\"error\""
                case StopReason.Aborted => "\"aborted\""
                case _ => "\"end_turn\""
            }
            let text = toText(e.message.content)
            "{\"type\":\"turn_end\",\"stopReason\":" + stopStr + ",\"content\":\"" + escapeJson(text) + "\"}"
        case e: MessageStartEvent =>
            let role = match (e.message) {
                case _: UserMessage => "\"user\""
                case _: AssistantMessage => "\"assistant\""
                case _: ToolResultMessage => "\"tool\""
                case _ => "\"unknown\""
            }
            "{\"type\":\"message_start\",\"role\":" + role + "}"
        case e: MessageUpdateEvent =>
            "{\"type\":\"message_update\",\"delta\":\"" + escapeJson(e.delta) + "\"}"
        case e: MessageEndEvent =>
            "{\"type\":\"message_end\"}"
        case e: ToolExecutionStartEvent =>
            "{\"type\":\"tool_execution_start\",\"toolName\":\"" + escapeJson(e.toolName) + "\"}"
        case e: ToolExecutionUpdateEvent =>
            "{\"type\":\"tool_execution_update\",\"toolName\":\"" + escapeJson(e.toolCallId) + "\",\"progress\":\"" + escapeJson(e.progress) + "\"}"
        case e: ToolExecutionEndEvent =>
            "{\"type\":\"tool_execution_end\",\"toolName\":\"" + escapeJson(e.toolCallId) + "\",\"isError\":" + e.isError.toString() + ",\"result\":\"" + escapeJson(e.result) + "\"}"
        case _: CompactionEvent =>
            "{\"type\":\"compaction\"}"
        case _ => "{\"type\":\"unknown\"}"
    }
    "data: " + json + "\n\n"
}

func configFromDTO(dto: AgentConfigDTO): AgentConfig {
    AgentConfig(dto.name, dto.description, dto.systemPrompt, None,
        dto.model, dto.provider, dto.tools, dto.skills, dto.mcpCooldownTurns,
        UInt32(dto.maxTurns), Float32(dto.temperature), UInt32(4096), None,
        true, None, UInt32(50), UInt32(30), UInt32(0),
        ArrayList(), None, 0, 0)
}

func toText(cl: ContentList): String {
    var r = ""
    for (b in cl.blocks()) {
        match (b) { case ContentBlock.TextBlock(t) => r = r + t; case _ => () }
    }
    r
}

func lastAssistantText(msgs: ArrayList<Message>): String {
    var i = msgs.size - 1
    while (i >= 0) {
        match (msgs[Int64(i)]) {
            case am: AssistantMessage => return toText(am.content)
            case _ => ()
        }
        i--
    }
    ""
}

func joinStrings(items: ArrayList<String>, sep: String): String {
    var r = ""
    for (i in 0..items.size) {
        if (i > 0) { r = r + sep }
        r = r + items[Int64(i)]
    }
    r
}
