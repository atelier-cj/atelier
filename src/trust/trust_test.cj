package atelier.trust

import atelier.tool.*
import jsonvalue.*
import std.collection.*

class MockParallelTool <: Tool {
    public func name(): String { "mock_parallel" }
    public func description(): String { "" }
    public func schema(): JsonValue { JsonValue.Map(HashMap<String, JsonValue>()) }
    public func execute(ctx: ToolContext, args: JsonValue): ToolResult { ToolResult("ok", None, false, false) }
    public func executionMode(): ToolExecutionMode { ToolExecutionMode.Parallel }
}

class MockSequentialTool <: Tool {
    public func name(): String { "mock_sequential" }
    public func description(): String { "" }
    public func schema(): JsonValue { JsonValue.Map(HashMap<String, JsonValue>()) }
    public func execute(ctx: ToolContext, args: JsonValue): ToolResult { ToolResult("ok", None, false, false) }
    public func executionMode(): ToolExecutionMode { ToolExecutionMode.Sequential }
}

func mockCtx(): ToolContext { ToolContext("/home/user/project") }

@Test
func shouldAllow_parallel_alwaysTrue() {
    let mgr = TrustManager()
    @Expect(shouldAllow(MockParallelTool(), "/tmp", mgr), true)
}

@Test
func shouldAllow_sequential_undecidedIsFalse() {
    let mgr = TrustManager()
    @Expect(shouldAllow(MockSequentialTool(), "/tmp", mgr), false)
}

@Test
func shouldAllow_sequential_trustedIsTrue() {
    let mgr = TrustManager()
    mgr.setTrust("/home/user/project", TrustState.Trusted)
    @Expect(shouldAllow(MockSequentialTool(), "/home/user/project", mgr), true)
}

@Test
func shouldAllow_sequential_untrustedIsFalse() {
    let mgr = TrustManager()
    mgr.setTrust("/home/user/project", TrustState.Untrusted)
    @Expect(shouldAllow(MockSequentialTool(), "/home/user/project", mgr), false)
}

@Test
func shouldAllow_sequential_parentTrusted() {
    let mgr = TrustManager()
    mgr.setTrust("/home/user", TrustState.Trusted)
    @Expect(shouldAllow(MockSequentialTool(), "/home/user/project/sub", mgr), true)
}

func isState(s: TrustState, expected: TrustState): Bool {
    match (s) {
        case expected => true
        case _ => false
    }
}

@Test
func getTrust_defaultIsUndecided() {
    let mgr = TrustManager()
    @Expect(isState(mgr.getTrust("/any/path"), TrustState.Undecided), true)
}

@Test
func getTrust_afterSet() {
    let mgr = TrustManager()
    mgr.setTrust("/a/b", TrustState.Trusted)
    @Expect(isState(mgr.getTrust("/a/b"), TrustState.Trusted), true)
}

@Test
func getTrust_sessionOverridesPersistent() {
    let mgr = TrustManager()
    mgr.setTrust("/path", TrustState.Untrusted)
    mgr.setSessionTrust("/path", TrustState.Trusted)
    @Expect(isState(mgr.getEffectiveTrust("/path"), TrustState.Trusted), true)
}

@Test
func getTrust_parentTraversal() {
    let mgr = TrustManager()
    mgr.setTrust("/a", TrustState.Trusted)
    @Expect(isState(mgr.getEffectiveTrust("/a/b/c"), TrustState.Trusted), true)
}
