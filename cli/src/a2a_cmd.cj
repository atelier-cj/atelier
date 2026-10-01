package cli

import std.env.*
import std.fs.{Directory, Path, exists}
import atelier.agent.*
import atelier.provider.*
import atelier.provider.EchoProvider
import atelier.a2a.A2aBridge
import a2a.*

// atelier a2a [agent] [port]：以 A2A v1 Agent（HTTP 服务端）对外提供服务。
// Agent Card 由 agent 配置 + 技能注册表生成，声明 JSON-RPC 绑定与流式能力；
// 一个 contextId = 一段会话，会话映射与会话数据同目录（跨进程可续聊）。
// workspace：工具工作目录（A2A 请求本身不带 cwd）。
public func runA2a(agentNameArg: String, spec: HarnessSpec, sessionDir: String,
    port: UInt16, workspace: String, host!: String = "127.0.0.1"): Unit {
    // agent 启动时选择：参数优先，未注册则回退 default（不存在则补建），与 acp 同规则
    let agentReg = spec.agents
    let agentName: String
    if (agentNameArg != "" && agentReg.has(agentNameArg)) {
        agentName = agentNameArg
    } else {
        agentName = "default"
        if (!agentReg.has("default")) {
            agentReg.create("default", AgentConfig.default())
        }
    }
    let cfg = match (agentReg.get(agentName)) {
        case Some(c) => c
        case None => AgentConfig.default()
    }
    // 离线通道：ATELIER_PROVIDER=echo 时用 EchoProvider（e2e/冒烟，不连真实 LLM）；
    // ATELIER_ECHO_DELAY_MS 可加延时供取消路径验证（与 acp 同约定）
    let echoMode = match (getVariable("ATELIER_PROVIDER")) {
        case Some(v) => v == "echo"
        case None => false
    }
    let provider: Provider = if (echoMode) {
        let delayMs = match (getVariable("ATELIER_ECHO_DELAY_MS")) {
            case Some(v) =>
                try { parseInt(v) } catch (_) { 0 }
            case None => 0
        }
        EchoProvider(delayMs)
    } else {
        spec.resolveProvider(cfg)
    }
    if (sessionDir != "" && !exists(Path(sessionDir))) {
        try {
            Directory.create(Path(sessionDir), recursive: true)
        } catch (e: Exception) {
            eprintln("[atelier] a2a session dir create failed (${sessionDir}): ${e.toString()}")
        }
    }
    let mappingFile = if (sessionDir != "") {
        sessionDir + "/a2a-sessions.json"
    } else {
        "a2a-sessions.json"
    }
    let bridge = A2aBridge(spec, cfg, provider, mappingFile, workspace)
    let baseUrl = "http://${host}:${port}"
    let server = A2aServer(bridge.agentCard(baseUrl, "0.1.12"), bridge,
        options: ServerOptions.of(streaming: true, pushNotifications: false))
    try {
        let err = getStdErr()
        err.write(("[atelier-a2a] agent='" + agentName + "' ready: " + baseUrl +
            " (card: " + baseUrl + AgentCardWellKnownPath + ")\n").toArray())
        err.flush()
    } catch (_) { () }
    server.serve(host, port)
}

// 命令行端口解析：非法输入回落到默认端口（命令行用法错误不该让服务静默起在别处）
public func parseA2aPort(raw: String, fallback: UInt16): UInt16 {
    try {
        let v = parseInt(raw)
        if (v <= 0 || v > 65535) {
            return fallback
        }
        UInt16(v)
    } catch (_) {
        fallback
    }
}
