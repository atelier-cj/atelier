package atelier.agent

import atelier.message.*
import atelier.tool.*
import atelier.provider.ChatRequest
import jsonvalue.*
import std.collection.*

public class HookContext {
    public let config: AgentConfig
    public let toolRegistry: ToolRegistry
    public let turnCount: Int64
    public let state: HookState

    public init(config: AgentConfig, toolRegistry: ToolRegistry,
        turnCount: Int64, state: HookState) {
        this.config = config
        this.toolRegistry = toolRegistry
        this.turnCount = turnCount
        this.state = state
    }
}

public interface Hook {
    public func beforeRun(ctx: HookContext): Unit {}
    public func afterRun(ctx: HookContext): Unit {}
    public func beforeTurn(ctx: HookContext, request: ChatRequest): TurnDecision {
        TurnDecision.Continue(request)
    }
    public func afterTurn(ctx: HookContext): AfterTurnUpdate {
        AfterTurnUpdate.none()
    }
    public func beforeTool(ctx: HookContext, call: ToolCallBlock): BeforeToolDecision {
        BeforeToolDecision.Allow
    }
    public func afterTool(ctx: HookContext, call: ToolCallBlock, result: ToolResultMessage): Unit {}
}
