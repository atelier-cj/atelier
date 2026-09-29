package atelier.agent

import atelier.tool.*
import atelier.message.*
import atelier.provider.*
import atelier.session.*
import atelier.trust.*
import atelier.skill.*
import jsonvalue.*
import std.collection.*
import stdx.log.*

public class AgentTool <: Tool {
    private let agentName: String
    private let config: AgentConfig
    private let provider: Provider
    private let toolRegistry: ToolRegistry
    private let sessionStore: SessionStore
    private let trustManager: TrustManager
    private let skillRegistry: SkillRegistry
    private let agentRegistry: AgentRegistry
    private let providerRegistry: ProviderRegistry
    private let mcpManager: McpManager

    public init(agentName: String, config: AgentConfig, provider: Provider,
        toolRegistry: ToolRegistry, sessionStore: SessionStore,
        trustManager: TrustManager, skillRegistry: SkillRegistry,
        agentRegistry: AgentRegistry, providerRegistry: ProviderRegistry,
        mcpManager: McpManager) {
        this.agentName = agentName
        this.config = config
        this.provider = provider
        this.toolRegistry = toolRegistry
        this.sessionStore = sessionStore
        this.trustManager = trustManager
        this.skillRegistry = skillRegistry
        this.agentRegistry = agentRegistry
        this.providerRegistry = providerRegistry
        this.mcpManager = mcpManager
    }

    public func name(): String {
        "agent_" + this.agentName
    }

    public func description(): String {
        match (this.config.description) {
            case Some(d) => "Run sub-agent '" + this.agentName + "': " + d
            case None => "Delegate task to sub-agent '" + this.agentName + "'"
        }
    }

    public func schema(): JsonValue {
        let obj = HashMap<String, JsonValue>()
        obj.add("type", JsonValue.String("object"))
        let props = HashMap<String, JsonValue>()
        let promptProp = HashMap<String, JsonValue>()
        promptProp.add("type", JsonValue.String("string"))
        promptProp.add("description", JsonValue.String("The task description to delegate"))
        props.add("prompt", JsonValue.Map(promptProp))
        obj.add("properties", JsonValue.Map(props))
        let req = ArrayList<JsonValue>()
        req.add(JsonValue.String("prompt"))
        obj.add("required", JsonValue.Array(req))
        JsonValue.Map(obj)
    }

    public func execute(ctx: ToolContext, args: JsonValue): ToolResult {
        let log = getGlobalLogger([("name", "AgentTool")])
        log.info("agent:${this.agentName} args: ${args}", Array<Attr>())
        let prompt: String = match (args["prompt"]) {
            case Some(JsonValue.String(s)) => s
            case _ =>
                log.warn("agent:${this.agentName} missing prompt in args", Array<Attr>())
                return ToolResult("Missing required parameter: prompt", None, true, false)
        }
        log.info("agent:${this.agentName} start", Array<Attr>())
        let runtime = AgentRuntime(this.config, this.provider,
            this.toolRegistry, this.sessionStore,
            this.trustManager, this.skillRegistry,
            this.agentRegistry, this.providerRegistry,
            this.mcpManager)
        let msgs = ArrayList<Message>()
        msgs.add(UserMessage(ContentList.ofText(prompt), 0))
        let stream = runtime.chat(msgs)
        let result = try {
            stream.result()
        } catch (e: Exception) {
            log.error("agent:${this.agentName} error: ${e.message}", Array<Attr>())
            return ToolResult("Sub-agent error: " + e.message, None, true, false)
        }
        let text = lastAgentText(result)
        log.info("agent:${this.agentName} done", Array<Attr>())
        ToolResult(text, None, false, false)
    }

    public func executionMode(): ToolExecutionMode {
        ToolExecutionMode.Sequential
    }
}

func lastAgentText(msgs: ArrayList<Message>): String {
    var i = msgs.size - 1
    while (i >= 0) {
        match (msgs[Int64(i)]) {
            case am: AssistantMessage =>
                var r = ""
                for (b in am.content.blocks()) {
                    match (b) { case ContentBlock.TextBlock(t) => r = r + t; case _ => () }
                }
                return r
            case _ => ()
        }
        i--
    }
    ""
}
