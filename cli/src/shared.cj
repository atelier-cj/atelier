package cli

import std.env.*
import std.fs.*
import std.collection.*
import stdx.net.http.*
import atelier.agent.*
import atelier.provider.*
import atelier.trust.*
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
 * 为什么需要这么一条通道：信任闸门在 `Undecided` 时靠 askUser 询问（TUI 在输入行回答、
 * ACP 走权限桥）。无人应答的调用方（CI、评测框架、批处理）没有回答通道 —— 默认 askUser
 * 直接返回空串，判定等同于拒绝，Sequential 工具（bash / write_file / edit_file）在那里
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
