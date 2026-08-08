package atelier.provider

import jsonvalue.*
import std.collection.*

public struct ProviderConfig {
    public let `type`: String
    public let name: String
    public let baseURL: String
    public let apiKey: String
    public let headers: ArrayList<String>
    public let extra: HashMap<String, JsonValue>

    public init(`type`: String, name: String, baseURL: String, apiKey: String,
        headers: ArrayList<String>, extra: HashMap<String, JsonValue>) {
        this.`type` = `type`; this.name = name; this.baseURL = baseURL
        this.apiKey = apiKey; this.headers = headers; this.extra = extra
    }

    public static func empty(`type`: String, name: String): ProviderConfig {
        ProviderConfig(`type`, name, "", "", ArrayList<String>(), HashMap<String, JsonValue>())
    }
}

public interface ProviderFactory {
    func `type`(): String
    func create(cfg: ProviderConfig): Provider
}

public class OpenAIFactory <: ProviderFactory {
    public func `type`(): String { "openai" }
    public func create(cfg: ProviderConfig): Provider {
        OpenAIProvider(cfg.name, cfg.baseURL, cfg.apiKey, cfg.headers)
    }
}

public class AnthropicFactory <: ProviderFactory {
    public func `type`(): String { "anthropic" }
    public func create(cfg: ProviderConfig): Provider {
        AnthropicProvider(cfg.name, cfg.baseURL, cfg.apiKey, cfg.headers)
    }
}

public class OllamaFactory <: ProviderFactory {
    public func `type`(): String { "ollama" }
    public func create(cfg: ProviderConfig): Provider {
        OllamaProvider(cfg.name, cfg.baseURL, cfg.headers)
    }
}
