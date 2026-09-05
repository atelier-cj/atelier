package atelier.acp

import std.collection.*
import jsonvalue.*
import acp.types.McpServer
import atelier.tool.{McpServerConfig}

// ACP session/new 携带的 MCP server 配置 → atelier McpServerConfig 映射。
// 形态映射：stdio（type=None/"stdio"）→ transport "stdio"（command）；
// type="http" → "streamable-http"（url + headers）；type="sse" 与未知形态 → None（不支持）。
// 边界：stdio 进程 env 无法表达（atelier stdio transport 无 env 注入）→ 忽略并交由调用方记录。
public func acpMcpServerToConfig(s: McpServer): ?McpServerConfig {
    let typ = match (s.`type`) {
        case Some(t) => t
        case None => "stdio"
    }
    if (typ == "stdio") {
        match (s.command) {
            case Some(cmd) =>
                if (cmd == "") { return None }
                Some(McpServerConfig(s.name, "stdio", cmd, ""))
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
