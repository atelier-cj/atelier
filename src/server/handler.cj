package atelier.server

import stdx.net.http.*
import std.io.ByteBuffer
import std.collection.*
import jsonvalue.*
import atelier.agent.*
import atelier.message.*
import atelier.provider.*
import atelier.tool.*
import atelier.session.*
import atelier.trust.*
import atelier.util.{toJsonString, fromJsonString}

public class AtelierHttpHandler {
    private let agentRegistry: AgentRegistry
    private let toolRegistry: ToolRegistry
    private let sessionStore: SessionStore
    private let trustManager: TrustManager
    private var providerRegistry: ProviderRegistry

    public init(agentRegistry: AgentRegistry, toolRegistry: ToolRegistry,
        sessionStore: SessionStore, trustManager: TrustManager) {
        this.agentRegistry = agentRegistry
        this.toolRegistry = toolRegistry
        this.sessionStore = sessionStore
        this.trustManager = trustManager
        this.providerRegistry = ProviderRegistry()
    }

    public func setProviderRegistry(reg: ProviderRegistry): Unit { this.providerRegistry = reg }

    public func registerRoutes(distributor: HttpRequestDistributor): Unit {
        let h = this
        distributor.register("/agent/config", { ctx => h.handleAgentConfig(ctx) })
        distributor.register("/agent/run", { ctx => h.handleAgentRun(ctx) })
        distributor.register("/agent/stream", { ctx => h.handleAgentStream(ctx) })
        distributor.register("/session/save", { ctx => h.handleSessionSave(ctx) })
        distributor.register("/session/load", { ctx => h.handleSessionLoad(ctx) })
        distributor.register("/health", { ctx => h.handleHealth(ctx) })
    }

    private func handleAgentConfig(ctx: HttpContext): Unit {
        match (ctx.request.method) {
            case "GET" =>
                let agents = this.agentRegistry.list()
                let arr = ArrayList<JsonValue>()
                for ((k, _) in agents) { arr.add(JsonValue.String(k)) }
                jsonResponse(ctx, 200, JsonValue.Array(arr).stringify())
            case "POST" =>
                let dto = try { fromJsonString<AgentConfigDTO>(readBody(ctx)) } catch (_) {
                    jsonResponse(ctx, 400, "{\"error\":\"invalid JSON\"}"); return
                }
                let cfg = configFromDTO(dto)
                try {
                    this.agentRegistry.create(dto.name, cfg)
                    jsonResponse(ctx, 201, "{\"status\":\"created\"}")
                } catch (e: Exception) {
                    jsonResponse(ctx, 409, "{\"error\":\"" + escapeJson(e.message) + "\"}")
                }
            case _ => jsonResponse(ctx, 405, "{\"error\":\"method not allowed\"}")
        }
    }

    private func handleAgentRun(ctx: HttpContext): Unit {
        let body = readBody(ctx)
        let dto = try { fromJsonString<ChatRequestDTO>(body) } catch (_) {
            jsonResponse(ctx, 400, "{\"error\":\"invalid JSON\"}"); return
        }
        let agentCfg = match (this.agentRegistry.get(dto.agent)) {
            case Some(c) => c
            case None => jsonResponse(ctx, 404, "{\"error\":\"agent not found\"}"); return
        }
        let msgs = ArrayList<Message>()
        for (m in dto.messages) {
            if (m.role == "user") { msgs.add(UserMessage(ContentList.ofText(m.content), 0)) }
        }
        let provider = resolveProvider(agentCfg.model)
        let runtime = AgentRuntime(agentCfg, provider, this.toolRegistry, this.sessionStore, this.trustManager)
        let eventStream = runtime.chat(msgs)
        let msgsResult = eventStream.result()
        let lastText = lastAssistantText(msgsResult)
        jsonResponse(ctx, 200, "{\"content\":\"" + escapeJson(lastText) + "\"}")
    }

    private func handleAgentStream(ctx: HttpContext): Unit {
        jsonResponse(ctx, 200, "{\"status\":\"SSE not yet implemented\"}")
    }

    private func handleSessionSave(ctx: HttpContext): Unit {
        jsonResponse(ctx, 200, "{\"status\":\"session saved\"}")
    }

    private func handleSessionLoad(ctx: HttpContext): Unit {
        let v = try { JsonValue.parse(readBody(ctx)) } catch (_) {
            jsonResponse(ctx, 400, "{\"error\":\"invalid JSON\"}"); return
        }
        let id = match (v["sessionId"]) { case Some(JsonValue.String(s)) => s; case _ => "" }
        if (id == "") { jsonResponse(ctx, 400, "{\"error\":\"missing sessionId\"}"); return }
        try {
            let msgs = this.sessionStore.load(id)
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
            jsonResponse(ctx, 200, "{\"sessionId\":\"" + id + "\",\"content\":\"" + escapeJson(text) + "\"}")
        } catch (_) {
            jsonResponse(ctx, 404, "{\"error\":\"session not found\"}")
        }
    }

    private func handleHealth(ctx: HttpContext): Unit {
        jsonResponse(ctx, 200, "{\"status\":\"ok\"}")
    }

    private func resolveProvider(model: String): Provider {
        match (this.providerRegistry.get("default")) {
            case Some(p) => p
            case None =>
                let p = OpenAIProvider("default", "http://localhost:8089", "")
                this.providerRegistry.register("default", p)
                p
        }
    }
}

func jsonResponse(ctx: HttpContext, code: Int64, body: String): Unit {
    let b = ctx.responseBuilder
    b.status(UInt16(code))
    b.header("content-type", "application/json")
    b.body(body)
}

func readBody(ctx: HttpContext): String {
    let buf = Array<Byte>(4096, repeat: 0)
    let all = ArrayList<Byte>()
    let input = ctx.request.body
    while (true) {
        let n: Int64
        try { n = input.read(buf) } catch (_) { break }
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

func configFromDTO(dto: AgentConfigDTO): AgentConfig {
    AgentConfig(dto.name, dto.description, dto.systemPrompt, None,
        dto.model, dto.provider, dto.tools, dto.skills,
        UInt32(dto.maxTurns), Float32(dto.temperature), UInt32(4096), None,
        true, UInt32(16384), UInt32(20000),
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
