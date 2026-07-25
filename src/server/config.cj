package atelier.server

import atelier.agent.*
import tomlcj.*
import stdx.serialization.serialization.*
import std.collection.*
import std.fs.*
import std.env.*

public class TomlConfig <: Serializable<TomlConfig> {
    public var agent: ArrayList<TomlAgent> = ArrayList()
    public var provider: ArrayList<TomlProvider> = ArrayList()
    public var logging: TomlLogging = TomlLogging()
    public var mcpServer: ArrayList<TomlMcpServer> = ArrayList()
    public init() {}

    public func serialize(): DataModel {
        DataModelStruct()
            .add(field<ArrayList<TomlAgent>>("agent", this.agent))
            .add(field<ArrayList<TomlProvider>>("provider", this.provider))
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
    public var baseURL: String = ""
    public var apiKey: String = ""
    public init() {}

    public func serialize(): DataModel {
        DataModelStruct()
            .add(field<String>("name", name))
            .add(field<String>("baseURL", baseURL))
            .add(field<String>("apiKey", apiKey))
    }

    public static func deserialize(dm: DataModel): TomlProvider {
        let dms = match (dm) { case s: DataModelStruct => s; case _ => throw Exception("expected struct") }
        let r = TomlProvider()
        r.name = match (dms.get("name")) { case s: DataModelString => s.getValue(); case _ => "" }
        r.baseURL = match (dms.get("baseURL")) { case s: DataModelString => s.getValue(); case _ => "" }
        r.apiKey = match (dms.get("apiKey")) { case s: DataModelString => s.getValue(); case _ => "" }
        r
    }
}

public class TomlMcpServer <: Serializable<TomlMcpServer> {
    public var name: String = ""
    public var transport: String = ""
    public var command: String = ""
    public var url: String = ""
    public init() {}

    public func serialize(): DataModel {
        DataModelStruct()
            .add(field<String>("name", name))
            .add(field<String>("transport", transport))
            .add(field<String>("command", command))
            .add(field<String>("url", url))
    }

    public static func deserialize(dm: DataModel): TomlMcpServer {
        let dms = match (dm) { case s: DataModelStruct => s; case _ => return TomlMcpServer() }
        let r = TomlMcpServer()
        r.name = match (dms.get("name")) { case s: DataModelString => s.getValue(); case _ => "" }
        r.transport = match (dms.get("transport")) { case s: DataModelString => s.getValue(); case _ => "" }
        r.command = match (dms.get("command")) { case s: DataModelString => s.getValue(); case _ => "" }
        r.url = match (dms.get("url")) { case s: DataModelString => s.getValue(); case _ => "" }
        r
    }
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

public struct ProviderConfig {
    public let name: String
    public let baseURL: String
    public let apiKey: String
    public init(name: String, baseURL: String, apiKey: String) {
        this.name = name; this.baseURL = baseURL; this.apiKey = apiKey
    }
}

public func resolveProvider(model: String): ProviderConfig {
    let baseURL = getEnv("OPENAI_BASE_URL", "https://api.openai.com/v1")
    let apiKey = getEnv("OPENAI_API_KEY", "")
    ProviderConfig("default", baseURL, apiKey)
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
        true, UInt32(16384), UInt32(20000), UInt32(50),
        ArrayList<String>(), None, 0, 0)
}

public func loadToml(path: String): TomlConfig {
    let p = Path(path)
    if (!exists(p)) { return TomlConfig() }
    try { unmarshal<TomlConfig>(path) } catch (_) { TomlConfig() }
}
