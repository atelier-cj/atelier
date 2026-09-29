package atelier.trust

import atelier.tool.*

public enum TrustDecision {
    | Allowed
    | NeedsApproval
    | Denied
}

public func shouldAllow(tool: Tool, workDir: String, trustManager: TrustManager): TrustDecision {
    shouldAllowFor(tool, workDir, trustManager, "")
}

// 会话感知判定：runtime/子 agent 等有会话 id 的调用点（per-session 信任隔离）
public func shouldAllowFor(tool: Tool, workDir: String, trustManager: TrustManager, sessionId: String): TrustDecision {
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
