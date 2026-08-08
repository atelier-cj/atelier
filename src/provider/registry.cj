package atelier.provider

import std.collection.*

public class ProviderRegistry {
    private let providers = HashMap<String, Provider>()
    private let factories = HashMap<String, ProviderFactory>()

    public init() {}

    public static func default(): ProviderRegistry {
        let reg = ProviderRegistry()
        reg.registerFactory(OpenAIFactory())
        reg.registerFactory(AnthropicFactory())
        reg.registerFactory(OllamaFactory())
        reg
    }

    public func register(name: String, provider: Provider) {
        this.providers[name] = provider
    }

    public func registerFactory(f: ProviderFactory) {
        this.factories[f.`type`()] = f
    }

    public func getFactory(`type`: String): Option<ProviderFactory> {
        this.factories.get(`type`)
    }

    public func create(cfg: ProviderConfig): Provider {
        match (this.factories.get(cfg.`type`)) {
            case Some(f) => f.create(cfg)
            case None => throw Exception("No provider factory for type: " + cfg.`type`)
        }
    }

    public func get(name: String): Option<Provider> {
        this.providers.get(name)
    }

    public func list(): ArrayList<Provider> {
        let result = ArrayList<Provider>()
        for ((_, p) in this.providers) { result.add(p) }
        result
    }

    public func has(name: String): Bool {
        this.providers.contains(name)
    }
}
