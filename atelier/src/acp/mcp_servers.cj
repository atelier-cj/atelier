package atelier.acp

import std.collection.*
import jsonvalue.*
import acp.types.McpServer
import atelier.tool.{McpServerConfig}

// ACP session/new 携带的 MCP server 配置 → atelier McpServerConfig 映射。
// 形态映射：stdio（type=None/"stdio"）→ transport "stdio"（command = command + args，env → cfg.env）；
// type="http" → "streamable-http"（url + headers）；type="sse" 与未知形态 → None（不支持）。
// 缺 command/url 的空配置同样返回 None，由调用方记录日志（不静默吞掉整条会话请求）。
public func acpMcpServerToConfig(s: McpServer): ?McpServerConfig {
    let typ = match (s.`type`) {
        case Some(t) => t
        case None => "stdio"
    }
    if (typ == "stdio") {
        match (s.command) {
            case Some(cmd0) =>
                if (cmd0 == "") { return None }
                // args 拼回 command（McpServerConfig/StdioClientTransport 为单命令串模型）
                var cmd = cmd0
                match (s.args) {
                    case Some(a) =>
                        for (a0 in a) { cmd = cmd + " " + a0 }
                    case None => ()
                }
                // stdio 进程 env：ACP EnvVariable → cfg.env（无 env 时保持旧构造）
                var envMap = HashMap<String, String>()
                match (s.env) {
                    case Some(evs) =>
                        for (ev in evs) {
                            if (ev.name != "") { envMap[ev.name] = ev.value }
                        }
                    case None => ()
                }
                if (envMap.size > 0) {
                    Some(McpServerConfig(s.name, "stdio", cmd, "", HashMap<String, String>(), envMap))
                } else {
                    Some(McpServerConfig(s.name, "stdio", cmd, ""))
                }
            case None => None
        }
    } else if (typ == "http") {
        match (s.url) {
            case Some(u) =>
                if (u == "") { return None }
                let headers = HashMap<String, String>()
                match (s.headers) {
                    case Some(hs) =>
                        for (h in hs) {
                            if (h.name != "") { headers[h.name] = h.value }
                        }
                    case None => ()
                }
                Some(McpServerConfig(s.name, "streamable-http", "", u, headers))
            case None => None
        }
    } else {
        // sse 及其它形态：atelier 无对应 transport
        None
    }
}
