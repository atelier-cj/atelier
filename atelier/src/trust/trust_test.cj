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

// ==================== TrustGate（函数类型闸门） ====================

// 默认闸门工厂：绑定给它的 manager —— 与改动前 shouldAllowFor 的行为逐条等价
@Test
public func trustGate_defaultMatchesLegacyBehavior() {
    let mgr = TrustManager()
    let gate: TrustGate = pathTrustGate(mgr)
    // Parallel 恒放行（与信任表无关）
    @Expect(isDecision(gate(MockParallelTool(), "/tmp", ""), TrustDecision.Allowed), true)
    @Expect(isDecision(gate(MockParallelTool(), "/nope/untrusted", "s1"), TrustDecision.Allowed), true)
    // Sequential：Undecided → 要问
    @Expect(isDecision(gate(MockSequentialTool(), "/tmp", ""), TrustDecision.NeedsApproval), true)
    // Sequential：Trusted → 放行
    mgr.setTrust("/home/user/project", TrustState.Trusted)
    @Expect(isDecision(gate(MockSequentialTool(), "/home/user/project", ""), TrustDecision.Allowed), true)
    // Sequential：Untrusted → 拒绝
    mgr.setTrust("/home/user/project", TrustState.Untrusted)
    @Expect(isDecision(gate(MockSequentialTool(), "/home/user/project", ""), TrustDecision.Denied), true)
}

// 闸门按会话隔离（默认实现保留 per-session 语义）
@Test
public func trustGate_defaultKeepsSessionIsolation() {
    let mgr = TrustManager()
    mgr.setSessionTrust("session_a", "/home/user/project", TrustState.Trusted)
    let gate: TrustGate = pathTrustGate(mgr)
    @Expect(isDecision(gate(MockSequentialTool(), "/home/user/project", "session_a"), TrustDecision.Allowed), true)
    @Expect(isDecision(gate(MockSequentialTool(), "/home/user/project", "session_b"), TrustDecision.NeedsApproval), true)
}

// 换掉闸门后行为真的变了（证明可替换，而非只是换了个名字）
@Test
public func trustGate_customGateReplacesDecision() {
    // 自定义策略：一律要问（比默认更严）
    let strict: TrustGate = { _, _, _ => TrustDecision.NeedsApproval }
    @Expect(isDecision(strict(MockParallelTool(), "/tmp", ""), TrustDecision.NeedsApproval), true)
    // 默认闸门对同一输入是放行 —— 两者结果不同，说明注入确实生效
    let mgr = TrustManager()
    @Expect(isDecision(pathTrustGate(mgr)(MockParallelTool(), "/tmp", ""), TrustDecision.Allowed), true)
}

// 自定义闸门可以只看工具名，不看信任表（宿主策略的典型形态）
@Test
public func trustGate_canPolicyByToolName() {
    let gate: TrustGate = { tool, _, _ =>
        if (tool.name() == "mock_sequential") { TrustDecision.Denied } else { TrustDecision.Allowed }
    }
    @Expect(isDecision(gate(MockSequentialTool(), "/anywhere", "s"), TrustDecision.Denied), true)
    @Expect(isDecision(gate(MockParallelTool(), "/anywhere", "s"), TrustDecision.Allowed), true)
}

// pathTrustGateWith 是核心逻辑：空 manager = 一切 Undecided（这不是默认行为，是默认故障）
@Test
public func trustGate_emptyManagerIsAllUndecided() {
    let empty = TrustManager()
    // Parallel 仍放行（不看信任表）
    @Expect(isDecision(pathTrustGateWith(MockParallelTool(), "/x", "", empty), TrustDecision.Allowed), true)
    // Sequential 一律要问 —— 所以"无状态默认闸门"不可写，必须由工厂绑定 manager
    @Expect(isDecision(pathTrustGateWith(MockSequentialTool(), "/x", "", empty), TrustDecision.NeedsApproval), true)
}
