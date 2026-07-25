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
    public init() {}

    public func serialize(): DataModel {
        DataModelStruct()
            .add(field<ArrayList<TomlAgent>>("agent", this.agent))
            .add(field<ArrayList<TomlProvider>>("provider", this.provider))
    }

    public static func deserialize(dm: DataModel): TomlConfig {
        let dms = match (dm) { case s: DataModelStruct => s; case _ => throw Exception("expected struct") }
        TomlConfig()
    }
}

public class TomlAgent <: Serializable<TomlAgent> {
    public var name: String = ""
    public var model: String = ""
    public var systemPrompt: String = ""
    public var description: String = ""
    public var provider: String = ""
    public var tools: ArrayList<String> = ArrayList()
    public init() {}

    public func serialize(): DataModel {
        DataModelStruct()
            .add(field<String>("name", name))
            .add(field<String>("model", model))
            .add(field<String>("systemPrompt", systemPrompt))
            .add(field<String>("provider", provider))
            .add(field<ArrayList<String>>("tools", tools))
    }

    public static func deserialize(dm: DataModel): TomlAgent {
        let dms = match (dm) { case s: DataModelStruct => s; case _ => throw Exception("expected struct") }
        let r = TomlAgent()
        r.name = String.deserialize(dms.get("name"))
        r.model = String.deserialize(dms.get("model"))
        r.systemPrompt = String.deserialize(dms.get("systemPrompt"))
        r.description = String.deserialize(dms.get("description"))
        r.provider = String.deserialize(dms.get("provider"))
        r.tools = ArrayList<String>.deserialize(dms.get("tools"))
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
        r.name = String.deserialize(dms.get("name"))
        r.baseURL = String.deserialize(dms.get("baseURL"))
        r.apiKey = String.deserialize(dms.get("apiKey"))
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
        a.tools, ArrayList<String>(),
        UInt32(20), Float32(0.7), UInt32(4096), None,
        true, UInt32(16384), UInt32(20000),
        ArrayList<String>(), None, 0, 0)
}

public func loadToml(path: String): TomlConfig {
    let p = Path(path)
    if (!exists(p)) { return TomlConfig() }
    try { unmarshal<TomlConfig>(path) } catch (_) { TomlConfig() }
}
