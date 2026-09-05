package atelier.cli

import std.env.*
import atelier.agent.*
import atelier.provider.*
import atelier.tool.*
import atelier.session.*
import atelier.trust.*
import atelier.skill.*
import atelier.context.ModelContextRegistry
import atelier.acp.AcpBridge

// atelier acp [agent]：以 ACP v1 Agent（stdio 服务端）身份被外部 ACP Client 拉起。
// 约束：本进程 stdout 只允许 ACP 帧，一切诊断走 stderr；serve() 阻塞至 stdin EOF。
public func runAcp(agentNameArg: String, toolReg: ToolRegistry, trustMgr: TrustManager,
    skillReg: SkillRegistry, agentReg: AgentRegistry, providerReg: ProviderRegistry,
    sessionStore: SessionStore, mcpMgr: McpManager, sessionDir: String): Unit {
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
    let cfg = match (agentReg.get(agentName)) {
        case Some(c) => c
        case None => AgentConfig.default()
    }
    let provider = resolveProviderFor(cfg, providerReg)
    // 会话映射文件与会话数据同目录（已由调用方创建）
    let mappingFile = if (sessionDir != "") { sessionDir + "/acp-sessions.json" } else { "acp-sessions.json" }
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
