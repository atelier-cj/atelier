package cli

import std.env.*
import std.fs.*
import stdx.net.http.*
import atelier.agent.*
import atelier.provider.*
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
