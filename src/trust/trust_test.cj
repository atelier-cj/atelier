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

func isDecision(d: TrustDecision, expected: TrustDecision): Bool {
    match (d) {
        case expected => true
        case _ => false
    }
}

@Test
func shouldAllow_parallel_alwaysAllowed() {
    let mgr = TrustManager()
    @Expect(isDecision(shouldAllow(MockParallelTool(), "/tmp", mgr), TrustDecision.Allowed), true)
}

@Test
func shouldAllow_sequential_undecidedNeedsApproval() {
    let mgr = TrustManager()
    @Expect(isDecision(shouldAllow(MockSequentialTool(), "/tmp", mgr), TrustDecision.NeedsApproval), true)
}

@Test
func shouldAllow_sequential_trustedIsAllowed() {
    let mgr = TrustManager()
    mgr.setTrust("/home/user/project", TrustState.Trusted)
    @Expect(isDecision(shouldAllow(MockSequentialTool(), "/home/user/project", mgr), TrustDecision.Allowed), true)
}

@Test
func shouldAllow_sequential_untrustedIsDenied() {
    let mgr = TrustManager()
    mgr.setTrust("/home/user/project", TrustState.Untrusted)
    @Expect(isDecision(shouldAllow(MockSequentialTool(), "/home/user/project", mgr), TrustDecision.Denied), true)
}

@Test
func shouldAllow_sequential_parentTrusted() {
    let mgr = TrustManager()
    mgr.setTrust("/home/user", TrustState.Trusted)
    @Expect(isDecision(shouldAllow(MockSequentialTool(), "/home/user/project/sub", mgr), TrustDecision.Allowed), true)
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

// ========== per-session 信任隔离（父子并发子 agent 场景） ==========

func trustIdx(s: TrustState): Int64 {
    match (s) {
        case TrustState.Undecided => 0
        case TrustState.Trusted => 1
        case TrustState.Untrusted => 2
    }
}

// 两个会话对同一目录各自授权，互不影响；不污染全局 "" 通道
@Test
public func trust_sessionIsolation() {
    let mgr = TrustManager()
    mgr.setSessionTrust("session_a", "/home/user/project", TrustState.Trusted)
    mgr.setSessionTrust("session_b", "/home/user/project", TrustState.Untrusted)
    @Expect(trustIdx(mgr.getEffectiveTrust("session_a", "/home/user/project")), trustIdx(TrustState.Trusted))
    @Expect(trustIdx(mgr.getEffectiveTrust("session_b", "/home/user/project")), trustIdx(TrustState.Untrusted))
    // 全局通道未被会话授权影响
    @Expect(trustIdx(mgr.getEffectiveTrust("/home/user/project")), trustIdx(TrustState.Undecided))
    // 未知会话回退全局
    @Expect(trustIdx(mgr.getEffectiveTrust("session_c", "/home/user/project")), trustIdx(TrustState.Undecided))
}

// 旧 2 参 API（无会话上下文）行为不变：精确路径命中
@Test
public func trust_legacySessionTrustCompatible() {
    let mgr = TrustManager()
    mgr.setSessionTrust("/data/x", TrustState.Trusted)
    @Expect(trustIdx(mgr.getEffectiveTrust("/data/x")), trustIdx(TrustState.Trusted))
    @Expect(trustIdx(mgr.getEffectiveTrust("/data/x/sub")), trustIdx(TrustState.Undecided))
}

// 会话信任沿父目录继承（per-session 内路径继承语义）
@Test
public func trust_sessionParentDirInherit() {
    let mgr = TrustManager()
    mgr.setSessionTrust("session_a", "/home/u/proj", TrustState.Trusted)
    @Expect(trustIdx(mgr.getEffectiveTrust("session_a", "/home/u/proj/sub/deep")), trustIdx(TrustState.Trusted))
    @Expect(trustIdx(mgr.getEffectiveTrust("session_b", "/home/u/proj/sub")), trustIdx(TrustState.Undecided))
}

// shouldAllowFor 按会话判定（Sequential 工具）：a 会话信任放行，b 会话需批准
@Test
public func trust_shouldAllowForUsesSession() {
    let mgr = TrustManager()
    mgr.setSessionTrust("session_a", "/home/user/project", TrustState.Trusted)
    let tool = MockSequentialTool()
    @Expect(isDecision(shouldAllowFor(tool, "/home/user/project", mgr, "session_a"), TrustDecision.Allowed), true)
    @Expect(isDecision(shouldAllowFor(tool, "/home/user/project", mgr, "session_b"), TrustDecision.NeedsApproval), true)
    // 无会话版本（旧行为）
    @Expect(isDecision(shouldAllow(tool, "/home/user/project", mgr), TrustDecision.NeedsApproval), true)
}
