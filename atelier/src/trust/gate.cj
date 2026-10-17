package atelier.trust

import atelier.tool.*

public enum TrustDecision {
    | Allowed
    | NeedsApproval
    | Denied
}

/**
 * 信任判定闸门：决定「这一次工具调用该不该放行」。
 *
 * 形态是**函数类型而不是 interface**：单方法、无状态，宿主一行 lambda 就能接
 * （与 `AskFn` / `PtcAuthorizer` 同一形态）。需要私有状态时用闭包捕获即可。
 *
 * 装配面见 `HarnessSpec.withTrustGate`；不注入时用 [pathTrustGate]（等价于改动前的行为）。
 */
public type TrustGate = (Tool, String, String) -> TrustDecision

/**
 * 默认闸门的**工厂**：给定信任表，产出一个绑定它的 [TrustGate]。
 *
 * 为什么是工厂而不是零参函数：判定必须查「该目录信任状态」，而信任状态只有
 * `TrustManager` 持有——没有无状态的默认闸门可写。硬造一个空 manager 会让所有目录
 * 恒定 `Undecided`（→ 所有副作用工具都被要求审批），那不是"默认行为"，是"默认故障"。
 *
 * 典型用法（宿主装配）：
 *
 * ```
 * spec.withTrustGate(pathTrustGate(trustManager))
 * ```
 */
public func pathTrustGate(trustManager: TrustManager): TrustGate {
    { tool, workDir, sessionId => pathTrustGateWith(tool, workDir, sessionId, trustManager) }
}

/**
 * 闸门的核心逻辑（纯函数，信任表作为参数传入）。
 *
 * 语义：
 * - `Parallel` 工具（只读语义）一律放行；
 * - `Sequential` 工具（有副作用）查该会话在该目录的信任状态：
 *   `Trusted` 放行 / `Undecided` 要问 / `Untrusted` 拒绝。
 *
 * @param tool 待判定的工具
 * @param workDir 本次调用的工作目录（信任表的键之一）
 * @param sessionId 会话 id（per-session 信任隔离；空串表示「无会话上下文」）
 * @param trustManager 信任表来源
 */
public func pathTrustGateWith(tool: Tool, workDir: String, sessionId: String,
    trustManager: TrustManager): TrustDecision {
    match (tool.executionMode()) {
        case ToolExecutionMode.Parallel =>
            Allowed
        case ToolExecutionMode.Sequential =>
            match (trustManager.getEffectiveTrust(sessionId, workDir)) {
                case TrustState.Trusted => Allowed
                case TrustState.Undecided => NeedsApproval
                case TrustState.Untrusted => Denied
            }
    }
}

// ==================== 兼容包装（矩阵迁移完成后可删） ====================
// 保留这两个自由函数是因为：① 既有调用点与单测按名字引用它们；② 它们表达的是
// 「用哪个 manager 判定」这件事，而 TrustGate 只表达「怎么判定」。
// 新增代码应当注入 TrustGate，不要新增对这两个函数的依赖。

public func shouldAllow(tool: Tool, workDir: String, trustManager: TrustManager): TrustDecision {
    shouldAllowFor(tool, workDir, trustManager, "")
}

// 会话感知判定：runtime/子 agent 等有会话 id 的调用点（per-session 信任隔离）
public func shouldAllowFor(tool: Tool, workDir: String, trustManager: TrustManager, sessionId: String): TrustDecision {
    pathTrustGateWith(tool, workDir, sessionId, trustManager)
}
