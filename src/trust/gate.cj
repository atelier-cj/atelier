package atelier.trust

import atelier.tool.*

public enum TrustDecision {
    | Allowed
    | NeedsApproval
    | Denied
}

public func shouldAllow(tool: Tool, workDir: String, trustManager: TrustManager): TrustDecision {
    match (tool.executionMode()) {
        case ToolExecutionMode.Parallel =>
            Allowed
        case ToolExecutionMode.Sequential =>
            match (trustManager.getEffectiveTrust(workDir)) {
                case TrustState.Trusted => Allowed
                case TrustState.Undecided => NeedsApproval
                case TrustState.Untrusted => Denied
            }
    }
}
