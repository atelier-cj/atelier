package atelier.provider

import jsonvalue.*
import std.collection.*

public struct ProviderConfig {
    public let name: String
    public let baseURL: String
    public let apiKey: String
    public let headers: ArrayList<String>
    public let extra: HashMap<String, JsonValue>

    public init(name: String, baseURL: String, apiKey: String,
        headers: ArrayList<String>, extra: HashMap<String, JsonValue>) {
        this.name = name; this.baseURL = baseURL
        this.apiKey = apiKey; this.headers = headers
        this.extra = extra
    }

    public static func empty(name: String): ProviderConfig {
        ProviderConfig(name, "", "", ArrayList<String>(), HashMap<String, JsonValue>())
    }
}

public interface ProviderFactory {
    func `type`(): String
    func create(cfg: ProviderConfig): Provider
}
