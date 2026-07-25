package atelier.agent

import atelier.message.*
import atelier.tool.*
import jsonvalue.*
import std.collection.*

public class HookContext {
    public let config: AgentConfig
    public let toolRegistry: ToolRegistry
    public let turnCount: Int64
    public let toolCalls: ArrayList<ToolCallBlock>
    public let toolResults: ArrayList<ToolResultMessage>

    public init(config: AgentConfig, toolRegistry: ToolRegistry,
        turnCount: Int64, toolCalls: ArrayList<ToolCallBlock>,
        toolResults: ArrayList<ToolResultMessage>) {
        this.config = config
        this.toolRegistry = toolRegistry
        this.turnCount = turnCount
        this.toolCalls = toolCalls
        this.toolResults = toolResults
    }
}

public interface Hook {
    func beforeRun(ctx: HookContext): Unit
    func afterRun(ctx: HookContext): Unit
    func beforeTurn(ctx: HookContext): Unit
    func afterTurn(ctx: HookContext): Unit
    func beforeTool(ctx: HookContext): Unit
    func afterTool(ctx: HookContext): Unit
}

public open class HookAdapter <: Hook {
    public init() {}
    public func beforeRun(ctx: HookContext): Unit {}
    public func afterRun(ctx: HookContext): Unit {}
    public func beforeTurn(ctx: HookContext): Unit {}
    public func afterTurn(ctx: HookContext): Unit {}
    public func beforeTool(ctx: HookContext): Unit {}
    public func afterTool(ctx: HookContext): Unit {}
}
