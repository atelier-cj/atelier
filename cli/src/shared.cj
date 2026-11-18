package cli

import std.env.*
import std.fs.*
import std.collection.*
import stdx.net.http.*
import atelier.agent.*
import atelier.provider.*
import atelier.trust.*
import atelier.a2a.AtelierVersion
import server.*

// 入口（cli.app）与 acp 命令共用的装配助手（自 main.cj 拆出，保持同一包可见性）

public func resolveProviderFor(cfg: AgentConfig, reg: ProviderRegistry): Provider {
    let providerName = match (cfg.provider) { case Some(v) => v; case None => "default" }
    match (reg.get(providerName)) {
        case Some(p) => p
        case None =>
            // Fallback: create from env
            let baseURL = match (getVariable("OPENAI_BASE_URL")) {
                case Some(v) => v; case None => "https://api.openai.com/v1"
            }
            let apiKey = match (getVariable("OPENAI_API_KEY")) {
                case Some(v) => v; case None => ""
            }
            OpenAIProvider(providerName, baseURL, apiKey)
    }
}

public func serve(handler: AtelierHttpHandler, host: String, port: String): Unit {
    let server = ServerBuilder()
        .addr(host)
        .port(UInt16(parseInt(port)))
        .build()
    handler.registerRoutes(server.distributor)
    println("Atelier HTTP server listening on ${host}:${port}")
    server.serve()
}

public func parseInt(s: String): Int64 {
    var r: Int64 = 0
    for (c in s.toArray()) {
        if (c >= 48 && c <= 57) { r = r * 10 + Int64(c - 48) }
        else { break }
    }
    r
}

/**
 * 当前可执行文件真实路径：Linux `/proc/self/exe` 符号链接递归解析。
 *
 * 解析失败回退 `"atelier.cli"`（依赖 PATH/相对路径）——远程子 Agent 进程由此启动。
 */
public func currentExePath(): String {
    try {
        let p = SymbolicLink.readFrom(Path("/proc/self/exe"), recursive: true)
        if (p.toString() != "") { return p.toString() }
    } catch (_) { () }
    "atelier.cli"
}

// ---------- 非交互信任通道（headless） ----------

/**
 * 解析 `ATELIER_TRUST_DIR`：`:` 分隔的可信工作目录列表。
 *
 * 为什么需要这么一条通道：信任闸门在 `Undecided` 时靠宿主提问（TUI 在输入行回答、
 * ACP 走 elicitation）。无人应答的调用方（CI、评测框架、批处理）没有提问通道 ——
 * 提问按取消处理，判定等同于拒绝，Sequential 工具（bash / write_file / edit_file）在那里
 * 全部不可用。本函数把「哪些目录可信」收敛为启动期的显式声明：只有拉起进程的一方能给出。
 *
 * 规则：`:` 分隔；跳过空白项（`::`、首尾分隔符）；去掉尾随 `/`（根 `/` 保留）；保序去重。
 */
public func parseTrustDirs(raw: String): ArrayList<String> {
    let out = ArrayList<String>()
    for (part in raw.split(":")) {
        var dir = part.trimAscii()
        while (dir.size > 1 && dir.endsWith("/")) {
            dir = dir[0..(dir.size - 1)]
        }
        if (dir == "") { continue }
        var dup = false
        for (d in out) {
            if (d == dir) { dup = true }
        }
        if (!dup) { out.add(dir) }
    }
    out
}

/**
 * 把 `ATELIER_TRUST_DIR` 声明的目录在启动期置为可信，返回实际生效的目录。
 *
 * 只认真实存在的目录：拼错的路径若被静默记下，等于给未来某个同名目录预授权 ——
 * 权限放大不报错，只会在事后变成「这个目录什么时候变可信了」的悬案。
 */
public func applyTrustFromEnv(trustMgr: TrustManager, raw: String): ArrayList<String> {
    let applied = ArrayList<String>()
    for (dir in parseTrustDirs(raw)) {
        if (!exists(Path(dir))) { continue }
        trustMgr.setTrust(dir, TrustState.Trusted)
        applied.add(dir)
    }
    applied
}

// ---------- 非启动命令的快速出口 ----------

/**
 * `--version` / `--help` 该在此处就结束：**不装配运行时、不碰磁盘**。
 *
 * 动机（实测数字）：入口是先装配后分发，于是连 `--version` 都会打开会话库。
 * 打开成本取决于库里遗留 `.mem`（WAL）的数量——288 个时单次 7–9 秒；
 * 而遗留文件恰恰又是「入口提前 return、没走到 close()」留下的，两者互为因果。
 * 探测方给的 RPC 上限通常只有十几秒，这条路径必须降到毫秒级。
 *
 * 返回 `Some(文本)` = 打印后以 0 退出；`None` = 继续按子命令装配。
 */
public func startupOutput(cmd: String): Option<String> {
    match (cmd) {
        case "-v" | "--version" => Some("atelier " + AtelierVersion)
        case "-h" | "--help" => Some(usageText())
        case _ => None
    }
}

/** 用法帮助；`--help` 与未知子命令共用同一份文本（避免两处各写一份逐渐漂移）。 */
public func usageText(): String {
    let b = StringBuilder()
    b.append("Atelier Agent Runtime\n")
    b.append("Usage:\n")
    b.append("  cli.app serve [port]          Start HTTP server\n")
    b.append("  cli.app acp [agent]           Serve as ACP v1 agent over stdio (agent picked at startup)\n")
    b.append("  cli.app a2a [agent] [port]    Serve as A2A v1 agent over HTTP (Agent Card + SSE, default port 8931)\n")
    b.append("  cli.app tui [agent] [sid]     Start interactive TUI (alias: repl; resume session if sid given)\n")
    b.append("  cli.app run [agent] <prompt>  Run single prompt\n")
    b.append("  cli.app --version             Print version\n")
    b.append("\n")
    b.append("TUI slash commands: /help, /agent, /session, /model, /models, /tools, /subagent, /trust, /untrust, /clear, /exit\n")
    b.append("Config: ~/.atelier.toml  — agent, provider, model, server, mcpServer, logging\n")
    b.append("Skills: ~/.agents/skills/<name>/SKILL.md\n")
    b.append("Logs:   ~/.atelier/atelier.log (set [logging] level = \"debug\")\n")
    b.append("Sessions: ~/.atelier/sessions/ (persistent, auto-save after each turn)")
    b.toString()
}
