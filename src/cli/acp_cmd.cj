package atelier.cli

import std.env.*
import std.fs.{Directory, Path}
import atelier.agent.*
import atelier.provider.*
import atelier.tool.*
import atelier.session.*
import atelier.trust.*
import atelier.skill.*
import atelier.context.ModelContextRegistry
import atelier.acp.AcpBridge
import atelier.provider.EchoProvider

// atelier acp [agent]：以 ACP v1 Agent（stdio 服务端）身份被外部 ACP Client 拉起。
// 约束：本进程 stdout 只允许 ACP 帧，一切诊断走 stderr；serve() 阻塞至 stdin EOF。
// sessionDirOverride：非空时覆盖会话目录（远程子进程隔离用，不与父共享 bstorm/映射文件）
public func runAcp(agentNameArg: String, toolReg: ToolRegistry, trustMgr: TrustManager,
    skillReg: SkillRegistry, agentReg: AgentRegistry, providerReg: ProviderRegistry,
    sessionStore: SessionStore, mcpMgr: McpManager, sessionDir: String,
    sessionDirOverride: String): Unit {
    // agent 启动时选择：参数优先，未注册则回退 default（不存在则补建）
    let agentName: String
    if (agentNameArg != "" && agentReg.has(agentNameArg)) {
        agentName = agentNameArg
    } else {
        agentName = "default"
        if (!agentReg.has("default")) {
            agentReg.create("default", AgentConfig.default())
        }
    }
    let effectiveSessionDir = if (sessionDirOverride != "") { sessionDirOverride } else { sessionDir }
    // 覆盖目录需存在（调用方（远程桥）负责创建）
    if (sessionDirOverride != "") {
        try { Directory.create(Path(effectiveSessionDir)) } catch (_) { () }
    }
    let cfg = match (agentReg.get(agentName)) {
        case Some(c) => c
        case None => AgentConfig.default()
    }
    // 离线通道：ATELIER_PROVIDER=echo 时使用 EchoProvider（e2e/冒烟，不连真实 LLM），
    // ATELIER_ECHO_DELAY_MS 可加延时供取消路径验证
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
        resolveProviderFor(cfg, providerReg)
    }
    // 会话映射文件与会话数据同目录（已由调用方创建）
    let mappingFile = if (effectiveSessionDir != "") { effectiveSessionDir + "/acp-sessions.json" } else { "acp-sessions.json" }
    let modelReg = ModelContextRegistry()
    let bridge = AcpBridge(agentName, cfg, provider, toolReg, trustMgr, skillReg,
        agentReg, providerReg, sessionStore, mcpMgr, modelReg, mappingFile,
        "atelier", "0.1.0")
    try {
        let err = getStdErr()
        err.write(("[atelier-acp] agent='" + agentName + "' ready (ACP v1, stdio)\n").toArray())
        err.flush()
    } catch (_) { () }
    bridge.serve()
}
