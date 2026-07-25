package atelier.provider

import std.collection.*

public class ProviderRegistry {
    private let providers = HashMap<String, Provider>()

    public init() {}

    public func register(name: String, provider: Provider) {
        this.providers[name] = provider
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
