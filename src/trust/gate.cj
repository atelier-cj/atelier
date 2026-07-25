package atelier.trust

import atelier.tool.*

public func shouldAllow(tool: Tool, workDir: String, trustManager: TrustManager): Bool {
    match (tool.executionMode()) {
        case ToolExecutionMode.Parallel =>
            // Read-only / parallel tools are always allowed
            true
        case ToolExecutionMode.Sequential =>
            // Side-effect tools need trust check
            let trust = trustManager.getEffectiveTrust(workDir)
            match (trust) {
                case TrustState.Trusted => true
                case TrustState.Undecided => false   // needs user confirmation
                case TrustState.Untrusted => false   // explicitly denied
            }
    }
}
