package cli

// CLI 共用助手（shared.cj）的单测。

import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import atelier.trust.*

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
