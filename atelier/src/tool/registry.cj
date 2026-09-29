package atelier.tool

import std.collection.*

/**
 * Registry for tools.
 *
 * Thread-safety is not required at this level; the runtime is expected
 * to configure tools before starting an Agent run.
 */
public class ToolRegistry {
    let tools: HashMap<String, Tool>

    public init() {
        this.tools = HashMap<String, Tool>()
    }

    /**
     * Register a tool. If a tool with the same name already exists,
     * it will be overwritten.
     */
    public func register(tool: Tool): Unit {
        this.tools.add(tool.name(), tool)
    }

    /**
     * Retrieve a tool by name.
     * Returns None if no tool with the given name is registered.
     */
    public func get(name: String): Option<Tool> {
        return this.tools.get(name)
    }

    /**
     * List all registered tools.
     */
    public func list(): ArrayList<Tool> {
        let result = ArrayList<Tool>()
        let values = this.tools.values()
        for (tool in values) {
            result.add(tool)
        }
        return result
    }

    /**
     * Remove a tool by name. Does nothing if the tool does not exist.
     */
    public func remove(name: String): Unit {
        this.tools.remove(name)
    }

    /**
     * Check whether a tool with the given name is registered.
     */
    public func has(name: String): Bool {
        return this.tools.contains(name)
    }
}
