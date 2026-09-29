package atelier.agent

// 工具工作目录的解析契约：**永远给出绝对路径**。
//
// 相对路径（"."）在信任闸门里是死路：信任表按 workDir 文本查表并沿父目录回退，
// 而 `/trust <abs>`、`ATELIER_TRUST_DIR` 登记的都是绝对路径 —— 键对不上，
// 于是无人在场的调用方（headless / 评测）拿到的永远是「user denied approval」。

import std.collection.HashMap
import atelier.session.SessionEnvironment
import atelier.tool.*
import atelier.tool.builtin.BashTool
import atelier.trust.*

func isAllowed(d: TrustDecision): Bool {
    match (d) {
        case TrustDecision.Allowed => true
        case _ => false
    }
}

@Test
func resolveWorkDir_fallsBackToAbsoluteCwd() {
    let dir = resolveWorkDir(SessionEnvironment())
    @Expect(dir != ".", true)
    @Expect(dir.startsWith("/"), true)
}

@Test
func resolveWorkDir_keepsExplicitSessionDirectory() {
    let env = SessionEnvironment("/tmp/atelier-workdir-test", HashMap<String, String>())
    @Expect(resolveWorkDir(env), "/tmp/atelier-workdir-test")
}

@Test
func trustRegisteredOnResolvedWorkDir_letsSequentialToolThrough() {
    // 端到端形状：登记（信任通道做的事）→ 判定（闸门做的事），中间不允许有「键形态不一致」
    let mgr = TrustManager()
    let workDir = resolveWorkDir(SessionEnvironment())
    mgr.setTrust(workDir, TrustState.Trusted)
    @Expect(isAllowed(shouldAllowFor(BashTool(), workDir, mgr, "sess_workdir_test")), true)
}

@Test
func relativeWorkDirCannotMatchAbsoluteTrustEntry() {
    // 反证：这正是修复前的形态 —— 相对键查不到绝对登记，Sequential 工具被拒
    let mgr = TrustManager()
    let workDir = resolveWorkDir(SessionEnvironment())
    mgr.setTrust(workDir, TrustState.Trusted)
    @Expect(isAllowed(shouldAllowFor(BashTool(), ".", mgr, "sess_workdir_test")), false)
}
