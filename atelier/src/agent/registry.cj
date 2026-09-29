package atelier.agent

import atelier.message.*
import std.collection.*

public class AgentRegistry {
    private let agents = HashMap<String, AgentConfig>()

    public init() {}

    public func create(name: String, config: AgentConfig): Unit {
        if (this.agents.contains(name)) {
            throw Exception("Agent already exists: " + name)
        }
        this.agents[name] = config
    }

    public func update(name: String, config: AgentConfig): Unit {
        if (!this.agents.contains(name)) {
            throw Exception("Agent not found: " + name)
        }
        this.agents[name] = config
    }

    public func get(name: String): Option<AgentConfig> {
        this.agents.get(name)
    }

    public func list(): ArrayList<(String, AgentConfig)> {
        let result = ArrayList<(String, AgentConfig)>()
        for ((k, v) in this.agents) { result.add((k, v)) }
        result
    }

    public func delete(name: String): Bool {
        if (this.agents.contains(name)) {
            this.agents.remove(name)
            true
        } else { false }
    }

    public func has(name: String): Bool {
        this.agents.contains(name)
    }

    public func size(): Int64 { this.agents.size }
}
