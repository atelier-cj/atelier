package atelier.server

import atelier.agent.*
import tomlcj.*
import std.collection.*
import std.fs.*
import std.io.*
import std.env.*

public struct AtelierConfig {
    public var agents: ArrayList<AgentConfig> = ArrayList()
    public var providers: ArrayList<ProviderConfig> = ArrayList()
    public init() {}

    public static func load(path: String): AtelierConfig {
        let fullPath = Path(path)
        if (!exists(fullPath)) { return AtelierConfig() }
        let data = File.readFrom(fullPath)
        let stream = ByteBuffer()
        stream.write(data)
        let decoder = Decoder(stream)
        let obj = try { decoder.decode() } catch (_) { return AtelierConfig() }
        let result = AtelierConfig()
        let agArr = try { obj["agent"].asArray() } catch (_) { return result }
        for (tv in agArr.value) {
            let tbl = try { tv.asObject() } catch (_) { continue }
            result.agents.add(makeConfig(tbl))
        }
        result
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
    let baseURL = getEnv("OPENAI_BASE_URL", "http://localhost:8089")
    let apiKey = getEnv("OPENAI_API_KEY", "")
    ProviderConfig("default", baseURL, apiKey)
}

func getEnv(key: String, def: String): String {
    match (getVariable(key)) {
        case Some(v) => v
        case None => def
    }
}

func makeConfig(tbl: TomlObject): AgentConfig {
    let d = AgentConfig.default()
    let tags = getStrList(tbl, "tags")
    AgentConfig(
        getStr(tbl, "name", d.name),
        getOptStr(tbl, "description"),
        getStr(tbl, "systemPrompt", d.systemPrompt), None,
        getStr(tbl, "model", d.model),
        getOptStr(tbl, "provider"),
        getStrList(tbl, "tools"),
        getStrList(tbl, "skills"),
        d.maxTurns, d.temperature, d.maxOutputTokens, None,
        d.compactionEnabled, d.compactionReserveTokens, d.keepRecentTokens,
        tags, None, 0, 0)
}

func getStr(tbl: TomlObject, key: String, def: String): String {
    if (tbl.contains(key)) {
        try { tbl[key].asString().value } catch (_) { def }
    } else { def }
}

func getOptStr(tbl: TomlObject, key: String): Option<String> {
    if (tbl.contains(key)) {
        try { Some(tbl[key].asString().value) } catch (_) { None }
    } else { None }
}

func getStrList(tbl: TomlObject, key: String): ArrayList<String> {
    let result = ArrayList<String>()
    if (!tbl.contains(key)) { return result }
    let arr = try { tbl[key].asArray() } catch (_) { return result }
    for (tv in arr.value) {
        let s = try { tv.asString().value } catch (_) { continue }
        result.add(s)
    }
    result
}
