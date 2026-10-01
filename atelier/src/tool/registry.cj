package atelier.tool

import std.collection.*

/**
 * Registry for tools.
 *
 * 支持**派生视图**（[derived]）：视图先查自己的工具，未命中回退到父表。按请求加入的工具
 * （如协议层传入的客户端工具）走视图，不必复制整张父表 —— 复制会让派生之后注册进父表的
 * 工具在视图里不可见（典型：运行中按需加载的 MCP 工具，本轮注册、本轮就该可用）。
 *
 * Thread-safety is not required at this level; the runtime is expected
 * to configure tools before starting an Agent run.
 */
public class ToolRegistry {
    // 父表：None = 根表（宿主直接持有并注册）
    let parent: ?ToolRegistry
    let tools: HashMap<String, Tool>
    // 视图里移除的父表工具名：遮蔽而不是删父表项（父表是共享的）
    let masked: HashSet<String>

    public init() {
        this.parent = None
        this.tools = HashMap<String, Tool>()
        this.masked = HashSet<String>()
    }

    private init(parent: ToolRegistry, tools: HashMap<String, Tool>, masked: HashSet<String>) {
        this.parent = parent
        this.tools = tools
        this.masked = masked
    }

    /**
     * 派生一个叠加视图：先查 [overlay]，未命中回退本表。
     *
     * 同名以 overlay 为准（不改本表，也不影响其它视图）；视图派生之后注册进本表的新工具，
     * 视图一样看得到。
     */
    public func derived(overlay: ArrayList<Tool>): ToolRegistry {
        let own = HashMap<String, Tool>()
        for (t in overlay) {
            own.add(t.name(), t)
        }
        ToolRegistry(this, own, HashSet<String>())
    }

    /**
     * Register a tool. If a tool with the same name already exists,
     * it will be overwritten.
     */
    public func register(tool: Tool): Unit {
        this.tools.add(tool.name(), tool)
        // 重新注册 = 撤销先前对本名的遮蔽
        this.masked.remove(tool.name())
    }

    /**
     * Retrieve a tool by name.
     * Returns None if no tool with the given name is registered.
     */
    public func get(name: String): Option<Tool> {
        if (this.masked.contains(name)) {
            return None
        }
        match (this.tools.get(name)) {
            case Some(t) => Some(t)
            case None => match (this.parent) {
                case Some(p) => p.get(name)
                case None => None
            }
        }
    }

    /**
     * List all registered tools.
     */
    public func list(): ArrayList<Tool> {
        let result = ArrayList<Tool>()
        let seen = HashSet<String>()
        for (tool in this.tools.values()) {
            if (!seen.contains(tool.name())) {
                seen.add(tool.name())
                result.add(tool)
            }
        }
        match (this.parent) {
            case Some(p) =>
                for (tool in p.list()) {
                    let name = tool.name()
                    if (this.masked.contains(name) || seen.contains(name)) {
                        continue
                    }
                    seen.add(name)
                    result.add(tool)
                }
            case None => ()
        }
        return result
    }

    /**
     * Remove a tool by name. Does nothing if the tool does not exist.
     *
     * 在派生视图上调用只遮蔽父表项，不动父表（父表是与其它视图共享的）。
     */
    public func remove(name: String): Unit {
        this.tools.remove(name)
        match (this.parent) {
            case Some(p) => if (p.has(name)) {
                this.masked.add(name)
            }
            case None => ()
        }
    }

    /**
     * Check whether a tool with the given name is registered.
     */
    public func has(name: String): Bool {
        match (this.get(name)) {
            case Some(_) => true
            case None => false
        }
    }
}
