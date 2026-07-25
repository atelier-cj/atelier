package atelier.tool

import mcp.McpClient
import mcp.transport.{StdioClientTransport, StatelessHttpClientTransport, SessionHttpClientTransport}
import mcp.types.Implementation
import mcp.types.{Tool as McpToolDef}
import ystyle::jsonrpc.Result
import ystyle::jsonrpc.Transport
import jsonvalue.*
import std.collection.*
import stdx.log.*

public struct McpServerConfig {
    public let name: String
    public let transport: String
    public let command: String
    public let url: String

    public init(name: String, transport: String, command: String, url: String) {
        this.name = name; this.transport = transport; this.command = command; this.url = url
    }
}

public class McpManager {
    let clients = HashMap<String, McpClient>()

    public init() {}

    public func addServer(reg: ToolRegistry, cfg: McpServerConfig): Unit {
        let log = getGlobalLogger([("name", "McpManager")])
        let transportObj = createTransport(cfg)
        match (transportObj) {
            case Some(t) =>
                let client = McpClient(t)
                let info = Implementation("atelier", "0.1.0")
                match (client.connect(info)) {
                    case Result.Ok(initResult) =>
                        log.info("mcp ${cfg.name} connected: ${initResult.serverInfo.name}", Array<Attr>())
                    case Result.Err(e) =>
                        log.error("mcp ${cfg.name} connect failed: ${e}", Array<Attr>())
                        return
                }
                match (client.listTools()) {
                    case Result.Ok(result) =>
                        for (toolDef in result.tools) {
                            let prefixed = "mcp_" + cfg.name + "_" + toolDef.name
                            let wrapper = MCPToolWrapper(client, toolDef, toolName: prefixed)
                            reg.register(wrapper)
                            log.info("mcp ${cfg.name}: registered ${prefixed}", Array<Attr>())
                        }
                    case Result.Err(e) =>
                        log.error("mcp ${cfg.name} listTools failed: ${e}", Array<Attr>())
                        client.close()
                        return
                }
                this.clients[cfg.name] = client
            case None => ()
        }
    }

    public func closeAll(): Unit {
        for ((_, client) in this.clients) {
            try { client.close() } catch (_) { () }
        }
        this.clients.clear()
    }
}

func createTransport(cfg: McpServerConfig): Option<Transport> {
    let log = getGlobalLogger([("name", "McpManager")])
    if (cfg.transport == "stdio") {
        if (cfg.command == "") { log.warn("mcp ${cfg.name}: missing command", Array<Attr>()); return Option<Transport>.None }
        Option<Transport>.Some(StdioClientTransport(cfg.command))
    } else if (cfg.transport == "streamable-http") {
        if (cfg.url == "") { log.warn("mcp ${cfg.name}: missing url", Array<Attr>()); return Option<Transport>.None }
        Option<Transport>.Some(StatelessHttpClientTransport(cfg.url))
    } else if (cfg.transport == "session-http") {
        if (cfg.url == "") { log.warn("mcp ${cfg.name}: missing url", Array<Attr>()); return Option<Transport>.None }
        Option<Transport>.Some(SessionHttpClientTransport(cfg.url))
    } else {
        log.warn("mcp ${cfg.name}: unknown transport ${cfg.transport}", Array<Attr>())
        Option<Transport>.None
    }
}
