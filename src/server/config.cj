package atelier.server

import atelier.agent.*
import atelier.provider.*
import atelier.tool.McpServerConfig
import tomlcj.*
import stdx.serialization.serialization.*
import stdx.encoding.json.ToJson
import std.collection.*
import std.fs.*
import std.env.*
import jsonvalue.*

public struct StoreType {
    public let name: String
    public init(name: String) { this.name = name }
}

public struct TrustMode {
    public let mode: String
    public init(mode: String) { this.mode = mode }
}

public struct LogFormat {
    public let format: String
    public init(format: String) { this.format = format }
}

public struct RateLimit {
    public let requestsPerMinute: Int64
    public init(requestsPerMinute: Int64) { this.requestsPerMinute = requestsPerMinute }
}

public struct ServerConfig {
    public let host: String
    public let port: UInt16
    public let sessionStore: String
    public let sessionDir: String
    public let authToken: Option<String>
    public let trustMode: String
    public let logLevel: String
    public let logFormat: String
    public let rateLimit: Option<Int64>

    public init(host: String, port: UInt16, sessionStore: String, sessionDir: String,
        authToken: Option<String>, trustMode: String, logLevel: String,
        logFormat: String, rateLimit: Option<Int64>) {
        this.host = host; this.port = port; this.sessionStore = sessionStore
        this.sessionDir = sessionDir; this.authToken = authToken
        this.trustMode = trustMode; this.logLevel = logLevel
        this.logFormat = logFormat; this.rateLimit = rateLimit
    }

    public static func default(): ServerConfig {
        ServerConfig("0.0.0.0", UInt16(8080), "bstorm", "", None, "ask", "", "text", None)
    }
}

public class TomlConfig <: Serializable<TomlConfig> {
    public var agent: ArrayList<TomlAgent> = ArrayList()
    public var provider: ArrayList<TomlProvider> = ArrayList()
    public var server: TomlServer = TomlServer()
    public var logging: TomlLogging = TomlLogging()
    public var mcpServer: ArrayList<TomlMcpServer> = ArrayList()
    public init() {}

    public func serialize(): DataModel {
        DataModelStruct()
            .add(field<ArrayList<TomlAgent>>("agent", this.agent))
            .add(field<ArrayList<TomlProvider>>("provider", this.provider))
            .add(field<TomlServer>("server", this.server))
            .add(field<TomlLogging>("logging", this.logging))
            .add(field<ArrayList<TomlMcpServer>>("mcpServer", this.mcpServer))
    }

    public static func deserialize(dm: DataModel): TomlConfig {
        let dms = match (dm) { case s: DataModelStruct => s; case _ => throw Exception("expected struct") }
        let r = TomlConfig()
        match (dms.get("agent")) {
            case seq: DataModelSeq =>
                for (elem in seq.getItems()) {
                    r.agent.add(TomlAgent.deserialize(elem))
                }
            case _ => ()
        }
        match (dms.get("provider")) {
            case seq: DataModelSeq =>
                for (elem in seq.getItems()) {
                    r.provider.add(TomlProvider.deserialize(elem))
                }
            case _ => ()
        }
        match (dms.get("server")) {
            case dm: DataModelStruct => r.server = TomlServer.deserialize(dm)
            case _ => ()
        }
        match (dms.get("logging")) {
            case dm: DataModelStruct => r.logging = TomlLogging.deserialize(dm)
            case _ => ()
        }
        match (dms.get("mcpServer")) {
            case seq: DataModelSeq =>
                for (elem in seq.getItems()) {
                    r.mcpServer.add(TomlMcpServer.deserialize(elem))
                }
            case _ => ()
        }
        r
    }
}

public class TomlServer <: Serializable<TomlServer> {
    public var host: String = "0.0.0.0"
    public var port: Int64 = 8080
    public var sessionStore: String = "bstorm"
    public var sessionDir: String = ""
    public var authToken: String = ""
    public var trustMode: String = "ask"
    public var logLevel: String = ""
    public var logFormat: String = "text"
    public var rateLimit: Int64 = 0
    public init() {}

    public func serialize(): DataModel {
        DataModelStruct()
            .add(field<String>("host", host))
            .add(field<Int64>("port", port))
            .add(field<String>("sessionStore", sessionStore))
            .add(field<String>("sessionDir", sessionDir))
            .add(field<String>("authToken", authToken))
            .add(field<String>("trustMode", trustMode))
            .add(field<String>("logLevel", logLevel))
            .add(field<String>("logFormat", logFormat))
            .add(field<Int64>("rateLimit", rateLimit))
    }

    public static func deserialize(dm: DataModel): TomlServer {
        let dms = match (dm) { case s: DataModelStruct => s; case _ => return TomlServer() }
        let r = TomlServer()
        r.host = match (dms.get("host")) { case s: DataModelString => s.getValue(); case _ => "0.0.0.0" }
        r.port = match (dms.get("port")) { case i: DataModelInt => i.getValue(); case _ => Int64(8080) }
        r.sessionStore = match (dms.get("sessionStore")) { case s: DataModelString => s.getValue(); case _ => "bstorm" }
        r.sessionDir = match (dms.get("sessionDir")) { case s: DataModelString => s.getValue(); case _ => "" }
        r.authToken = match (dms.get("authToken")) { case s: DataModelString => s.getValue(); case _ => "" }
        r.trustMode = match (dms.get("trustMode")) { case s: DataModelString => s.getValue(); case _ => "ask" }
        r.logLevel = match (dms.get("logLevel")) { case s: DataModelString => s.getValue(); case _ => "" }
        r.logFormat = match (dms.get("logFormat")) { case s: DataModelString => s.getValue(); case _ => "text" }
        r.rateLimit = match (dms.get("rateLimit")) { case i: DataModelInt => i.getValue(); case _ => Int64(0) }
        r
    }

    public func toServerConfig(): ServerConfig {
        ServerConfig(
            this.host, UInt16(this.port), this.sessionStore, this.sessionDir,
            if (this.authToken == "") { None } else { Some(this.authToken) },
            this.trustMode, this.logLevel, this.logFormat,
            if (this.rateLimit > 0) { Some(this.rateLimit) } else { None })
    }
}

public class TomlAgent <: Serializable<TomlAgent> {
    public var name: String = ""
    public var model: String = ""
    public var systemPrompt: String = ""
    public var description: String = ""
    public var provider: String = ""
    public var tools: ArrayList<String> = ArrayList()
    public var skills: ArrayList<String> = ArrayList()
    public init() {}

    public func serialize(): DataModel {
        DataModelStruct()
            .add(field<String>("name", name))
            .add(field<String>("model", model))
            .add(field<String>("systemPrompt", systemPrompt))
            .add(field<String>("provider", provider))
            .add(field<ArrayList<String>>("tools", tools))
            .add(field<ArrayList<String>>("skills", skills))
    }

    public static func deserialize(dm: DataModel): TomlAgent {
        let dms = match (dm) { case s: DataModelStruct => s; case _ => throw Exception("expected struct") }
        let r = TomlAgent()
        r.name = match (dms.get("name")) { case s: DataModelString => s.getValue(); case _ => "" }
        r.model = match (dms.get("model")) { case s: DataModelString => s.getValue(); case _ => "" }
        r.systemPrompt = match (dms.get("systemPrompt")) { case s: DataModelString => s.getValue(); case _ => "" }
        r.description = match (dms.get("description")) { case s: DataModelString => s.getValue(); case _ => "" }
        r.provider = match (dms.get("provider")) { case s: DataModelString => s.getValue(); case _ => "" }
        match (dms.get("tools")) {
            case seq: DataModelSeq =>
                for (e in seq.getItems()) {
                    match (e) { case s: DataModelString => r.tools.add(s.getValue()); case _ => () }
                }
            case _ => ()
        }
        match (dms.get("skills")) {
            case seq: DataModelSeq =>
                for (e in seq.getItems()) {
                    match (e) { case s: DataModelString => r.skills.add(s.getValue()); case _ => () }
                }
            case _ => ()
        }
        r
    }
}

public class TomlProvider <: Serializable<TomlProvider> {
    public var name: String = ""
    public var providerType: String = "openai"
    public var baseURL: String = ""
    public var apiKey: String = ""
    public var headers: ArrayList<String> = ArrayList()
    public var extra: DataModel = DataModelNull()
    public init() {}

    public func serialize(): DataModel {
        DataModelStruct()
            .add(field<String>("name", name))
            .add(field<String>("type", providerType))
            .add(field<String>("baseURL", baseURL))
            .add(field<String>("apiKey", apiKey))
            .add(field<ArrayList<String>>("headers", headers))
            .add(Field("extra", this.extra))
    }

    public static func deserialize(dm: DataModel): TomlProvider {
        let dms = match (dm) { case s: DataModelStruct => s; case _ => throw Exception("expected struct") }
        let r = TomlProvider()
        r.name = match (dms.get("name")) { case s: DataModelString => s.getValue(); case _ => "" }
        r.providerType = match (dms.get("type")) { case s: DataModelString => s.getValue(); case _ => "openai" }
        r.baseURL = match (dms.get("baseURL")) { case s: DataModelString => s.getValue(); case _ => "" }
        r.apiKey = match (dms.get("apiKey")) { case s: DataModelString => s.getValue(); case _ => "" }
        match (dms.get("headers")) {
            case seq: DataModelSeq =>
                for (e in seq.getItems()) {
                    match (e) { case s: DataModelString => r.headers.add(s.getValue()); case _ => () }
                }
            case _ => ()
        }
        r.extra = dms.get("extra")
        r
    }
}

public func toProviderConfig(tp: TomlProvider): ProviderConfig {
    let extra = HashMap<String, JsonValue>()
    let jv = JsonValue.parse(tp.extra.toJson().toJsonString())
    match (jv) {
        case JsonValue.Map(m) =>
            for ((k, v) in m) { extra[k] = v }
        case _ => ()
    }
    ProviderConfig(tp.providerType, tp.name, tp.baseURL, tp.apiKey,
        tp.headers, extra)
}

public class TomlMcpServer <: Serializable<TomlMcpServer> {
    public var name: String = ""
    public var transport: String = ""
    public var command: String = ""
    public var url: String = ""
    public var headerList: ArrayList<String> = ArrayList()
    public init() {}

    public func serialize(): DataModel {
        DataModelStruct()
            .add(field<String>("name", name))
            .add(field<String>("transport", transport))
            .add(field<String>("command", command))
            .add(field<String>("url", url))
            .add(field<ArrayList<String>>("headers", headerList))
    }

    public static func deserialize(dm: DataModel): TomlMcpServer {
        let dms = match (dm) { case s: DataModelStruct => s; case _ => return TomlMcpServer() }
        let r = TomlMcpServer()
        r.name = match (dms.get("name")) { case s: DataModelString => s.getValue(); case _ => "" }
        r.transport = match (dms.get("transport")) { case s: DataModelString => s.getValue(); case _ => "" }
        r.command = match (dms.get("command")) { case s: DataModelString => s.getValue(); case _ => "" }
        r.url = match (dms.get("url")) { case s: DataModelString => s.getValue(); case _ => "" }
        match (dms.get("headers")) {
            case seq: DataModelSeq =>
                for (e in seq.getItems()) {
                    match (e) { case s: DataModelString => r.headerList.add(s.getValue()); case _ => () }
                }
            case _ => ()
        }
        r
    }

    public func toMcpServerConfig(): McpServerConfig {
        let hdrs = HashMap<String, String>()
        for (h in this.headerList) {
            let colonIdx = h.indexOf(":")
            match (colonIdx) {
                case Some(idx) =>
                    let key = trimStr(h[0..idx])
                    let val = trimStr(h[(idx + 1)..])
                    hdrs[key] = val
                case None => ()
            }
        }
        McpServerConfig(this.name, this.transport, this.command, this.url, hdrs)
    }
}

func trimStr(s: String): String {
    var start: Int64 = 0
    var end = s.size - 1
    while (start < s.size && s[start] <= 32) { start++ }
    while (end > start && s[end] <= 32) { end-- }
    if (start == 0 && end == s.size - 1) { s } else { s[start..(end + 1)] }
}

public class TomlLogging <: Serializable<TomlLogging> {
    public var level: String = ""
    public init() {}

    public func serialize(): DataModel {
        DataModelStruct()
            .add(field<String>("level", level))
    }

    public static func deserialize(dm: DataModel): TomlLogging {
        let dms = match (dm) { case s: DataModelStruct => s; case _ => return TomlLogging() }
        let r = TomlLogging()
        r.level = match (dms.get("level")) { case s: DataModelString => s.getValue(); case _ => "" }
        r
    }
}

public func resolveModel(cfgModel: String): String {
    let fromEnv = getEnv("OPENAI_MODEL", "")
    if (cfgModel != "") { cfgModel }
    else if (fromEnv != "") { fromEnv }
    else { "gpt-4o" }
}

func getEnv(key: String, def: String): String {
    match (getVariable(key)) {
        case Some(v) => v
        case None => def
    }
}

public func agentConfigFrom(a: TomlAgent): AgentConfig {
    AgentConfig(
        a.name,
        if (a.description == "") { None } else { Some(a.description) },
        a.systemPrompt, None,
        a.model,
        if (a.provider == "") { None } else { Some(a.provider) },
        a.tools, a.skills,
        UInt32(20), Float32(0.7), UInt32(4096), None,
        true, UInt32(16384), UInt32(20000), UInt32(50), UInt32(30), UInt32(0),
        ArrayList<String>(), None, 0, 0)
}

public func loadToml(path: String): TomlConfig {
    let p = Path(path)
    if (!exists(p)) { return TomlConfig() }
    try { unmarshal<TomlConfig>(path) } catch (_) { TomlConfig() }
}
