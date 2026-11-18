package cli

// CLI 共用助手（shared.cj）的单测。

import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import std.collection.*
import atelier.trust.*
import atelier.agent.*
import atelier.provider.*
import atelier.tool.*
import atelier.session.*
import atelier.skill.*

@Test
func currentExePath_resolvesNonEmpty() {
    @Expect(currentExePath() != "", true)
}

// ---------- 非交互信任通道（ATELIER_TRUST_DIR） ----------

func isTrustedState(state: TrustState): Bool {
    match (state) {
        case TrustState.Trusted => true
        case _ => false
    }
}

@Test
func parseTrustDirs_splitsAndTrimsItems() {
    let dirs = parseTrustDirs("/a:/b/c")
    @Expect(dirs.size, 2)
    @Expect(dirs[0], "/a")
    @Expect(dirs[1], "/b/c")
}

@Test
func parseTrustDirs_skipsBlankItems() {
    // 首尾分隔符与 `::` 都产生空白项：不跳过就会把 "" 变成「信任空路径」
    let dirs = parseTrustDirs(":/a::/b:")
    @Expect(dirs.size, 2)
    @Expect(dirs[0], "/a")
    @Expect(dirs[1], "/b")
}

@Test
func parseTrustDirs_stripsTrailingSlashButKeepsRoot() {
    // 尾随 `/` 不归一化会与无斜杠写法成为两条不同记录（TrustManager 的 normalize 是恒等）
    let dirs = parseTrustDirs("/a/b/:/")
    @Expect(dirs.size, 2)
    @Expect(dirs[0], "/a/b")
    @Expect(dirs[1], "/")
}

@Test
func parseTrustDirs_dedupesKeepingFirstOccurrence() {
    let dirs = parseTrustDirs("/a:/b:/a")
    @Expect(dirs.size, 2)
    @Expect(dirs[0], "/a")
    @Expect(dirs[1], "/b")
}

@Test
func parseTrustDirs_blankInputYieldsNothing() {
    @Expect(parseTrustDirs("").size, 0)
    @Expect(parseTrustDirs("   ").size, 0)
}

@Test
func applyTrustFromEnv_trustsExistingDirAndItsChildren() {
    let mgr = TrustManager()
    let applied = applyTrustFromEnv(mgr, "/tmp")
    @Expect(applied.size, 1)
    @Expect(isTrustedState(mgr.getEffectiveTrust("/tmp/atelier-bench-sandbox")), true)
}

@Test
func applyTrustFromEnv_skipsMissingDir() {
    // 不存在的路径被静默记下 = 给未来同名目录预授权；必须只认真实存在的目录
    let mgr = TrustManager()
    let missing = "/tmp/atelier-missing-dir-9f3a71"
    @Expect(exists(Path(missing)), false)
    @Expect(applyTrustFromEnv(mgr, missing).size, 0)
    @Expect(isTrustedState(mgr.getEffectiveTrust(missing)), false)
}

@Test
func applyTrustFromEnv_emptyLeavesUndecided() {
    let mgr = TrustManager()
    @Expect(applyTrustFromEnv(mgr, "").size, 0)
    @Expect(isTrustedState(mgr.getEffectiveTrust("/tmp")), false)
}

// ---------- 测试装配助手：CLI 侧组件收成一个装配束 ----------

func cliTestSpec(toolReg: ToolRegistry, store: SessionStore, trustMgr: TrustManager,
    skillReg: SkillRegistry, agentReg: AgentRegistry, providerReg: ProviderRegistry,
    mcpMgr: McpManager, provider: Provider): HarnessSpec {
    HarnessSpec(tools: toolReg, store: store, trust: trustMgr, skills: skillReg,
        agents: agentReg, providers: providerReg, mcp: mcpMgr)
        .withProvider("default", provider)
}

// ---------- 非启动命令的快速出口 ----------
// 动机：入口先装配后分发，`--version` 曾经要打开会话库（库里遗留 .mem 多时 7–9 秒）。
// 这两条用例钉的是「命令分类」，时序由 LazySessionStore 的用例保证。

@Test
func startupOutput_versionPrintsVersionAndNoUsage() {
    let out = startupOutput("--version")
    @Expect(out.isSome(), true)
    match (out) {
        case Some(text) =>
            // 必须带版本号且只有一行：探测方按行解析，混进用法帮助等于没有版本号
            @Expect(text.startsWith("atelier "), true)
            @Expect(text.contains("Usage:"), false)
            @Expect(text.split("\n").size, 1)
            @Expect(text.trimAscii().size > "atelier ".size, true)
        case None => @Fail("--version 没有快速出口")
    }
    // -v 同义
    match (startupOutput("-v")) {
        case Some(t) => @Expect(t, out.getOrThrow())
        case None => @Fail("-v 没有快速出口")
    }
}

@Test
func startupOutput_helpPrintsUsage() {
    for (f in ["--help", "-h"]) {
        match (startupOutput(f)) {
            case Some(text) =>
                @Expect(text.contains("Usage:"), true)
                @Expect(text.contains("acp"), true)
                // 帮助里要提到 --version，否则用户不知道有这个入口
                @Expect(text.contains("--version"), true)
            case None => @Fail("${f} 没有快速出口")
        }
    }
}

@Test
func startupOutput_startCommandsGoThrough() {
    // 真正的子命令必须返回 None，交给装配流程
    for (c in ["serve", "acp", "a2a", "tui", "repl", "run", ""]) {
        @Expect(startupOutput(c).isNone(), true)
    }
}
