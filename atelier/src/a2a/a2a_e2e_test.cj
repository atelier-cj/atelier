package atelier.a2a

import std.collection.*
import std.core.Duration
import std.fs.*
import a2a.*
import a2a.client.A2aClient
import atelier.agent.*
import atelier.provider.{EchoProvider, ProviderRegistry}
import atelier.session.MemorySessionStore
import atelier.skill.SkillRegistry
import atelier.tool.{McpManager, ToolRegistry}
import atelier.trust.TrustManager

// ===================== 端到端：本地 A2A server + 远端子 Agent 句柄 =====================
//
// 起一个真 HTTP 的 A2A 服务（执行器是 A2aBridge + EchoProvider，不访问网络/LLM），
// 再用 RemoteA2aSubAgentHandle 当客户端调用它：覆盖 Agent Card 发现、JSON-RPC 流式消息、
// 产物累积、终态收流、同 context 的多任务续聊。

private func a2aE2eTempDir(): String {
    Directory.createTemp(Path("/tmp")).toString()
}

private func a2aE2eCleanup(dir: String): Unit {
    try { remove(Path(dir), recursive: true) } catch (_) { () }
}

private func a2aE2eSpec(): HarnessSpec {
    HarnessSpec(tools: ToolRegistry(), store: MemorySessionStore(), trust: TrustManager(),
        skills: SkillRegistry(), agents: AgentRegistry(), providers: ProviderRegistry(),
        mcp: McpManager())
}

private func a2aE2eConfig(): AgentConfig {
    AgentConfig("echo-agent", Some("回显测试 agent"), "你是测试 agent", None,
        "echo", None, ArrayList<String>(), ArrayList<String>(), 0,
        4, 0.0, 1024, None, false, None, 8, 30, 0,
        ArrayList<String>(), None, 0, 0)
}

// 探一个空闲端口：起一个 port=0 的临时服务读回系统分配值，随即关掉。
// 卡片里的 interface.url 必须是真实地址（客户端按它发请求），所以端口得在建服务之前定下来。
private func a2aE2eFreePort(): UInt16 {
    let card = buildAgentCard("probe", "", "0", "http://127.0.0.1:0")
    let probe = A2aServer(card, a2aE2eNoopExecutor(), options: ServerOptions.of(streaming: true))
    let srv = probe.serveAsync("127.0.0.1", 0)
    let port = probe.boundPort()
    srv.close()
    port
}

class a2aE2eNoopExecutor <: A2aExecutor {
    public func execute(ctx: RequestContext, queue: EventQueue): Unit {}
    public func cancel(ctx: RequestContext, queue: EventQueue): Unit {}
}

// Agent Card 能被客户端发现（服务端 /.well-known/agent-card.json 路由）
@Test
func a2aE2e_discoversAgentCardOverHttp() {
    let dir = a2aE2eTempDir()
    let bridge = A2aBridge(a2aE2eSpec(), a2aE2eConfig(), EchoProvider(),
        dir + "/a2a-sessions.json", dir)
    let port = a2aE2eFreePort()
    let baseUrl = "http://127.0.0.1:${port}"
    let server = A2aServer(bridge.agentCard(baseUrl, "0.1.12"), bridge,
        options: ServerOptions.of(streaming: true, pushNotifications: false))
    let srv = server.serveAsync("127.0.0.1", port)
    let card = A2aClient.discover(baseUrl)
    @Expect(card.name, "echo-agent")
    @Expect(card.capabilities.streaming, true)
    match (card.interfaceFor(BindingJsonRpc)) {
        case Some(i) => @Expect(i.url, baseUrl)
        case None => @Fail("card missing JSONRPC interface")
    }
    srv.close()
    a2aE2eCleanup(dir)
}

// 远端子 Agent 句柄：首回合拿到 done 回信，第二回合在同一 context 上开新任务续聊
@Test
func a2aE2e_remoteSubAgentStreamsReplies() {
    let dir = a2aE2eTempDir()
    let bridge = A2aBridge(a2aE2eSpec(), a2aE2eConfig(), EchoProvider(),
        dir + "/a2a-sessions.json", dir)
    let port = a2aE2eFreePort()
    let baseUrl = "http://127.0.0.1:${port}"
    let server = A2aServer(bridge.agentCard(baseUrl, "0.1.12"), bridge,
        options: ServerOptions.of(streaming: true, pushNotifications: false))
    let srv = server.serveAsync("127.0.0.1", port)

    let h = RemoteA2aSubAgentHandle("a2a_1", "parent_1", baseUrl, { _ => () })
    h.serveRemote()
    h.send(AgentMail("parent_1", "a2a_1", AgentMailKindUserText, "你好"))
    match (h.recv(timeout: 30 * Duration.second)) {
        case Some(m) =>
            @Expect(m.kind, AgentMailKindDone)
            @Expect(m.text.contains("echo: 你好"), true)
        case None => @Fail("首回合没有回信")
    }
    // 第二回合：终态任务不再接受消息，句柄应开新任务（contextId 相同）
    h.send(AgentMail("parent_1", "a2a_1", AgentMailKindUserText, "再来一句"))
    match (h.recv(timeout: 30 * Duration.second)) {
        case Some(m) =>
            @Expect(m.kind, AgentMailKindReply)
            @Expect(m.text.contains("echo: 再来一句"), true)
        case None => @Fail("第二回合没有回信")
    }
    // 服务端侧：一个 context（同一 atelier 会话）+ 两个任务
    @Expect(bridge.sessions().size(), Int64(1))
    @Expect(bridge.sessions().taskSize(), Int64(2))

    h.close()
    srv.close()
    a2aE2eCleanup(dir)
}
