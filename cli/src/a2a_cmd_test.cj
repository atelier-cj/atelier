package cli

// 命令行端口解析：合法值原样，非法/越界回落到缺省端口
@Test
func a2aCmd_parsePort() {
    @Expect(parseA2aPort("8931", UInt16(1)), UInt16(8931))
    @Expect(parseA2aPort("65535", UInt16(1)), UInt16(65535))
    @Expect(parseA2aPort("abc", UInt16(8931)), UInt16(8931))
    @Expect(parseA2aPort("", UInt16(8931)), UInt16(8931))
    @Expect(parseA2aPort("0", UInt16(8931)), UInt16(8931))
    @Expect(parseA2aPort("-1", UInt16(8931)), UInt16(8931))
    @Expect(parseA2aPort("70000", UInt16(8931)), UInt16(8931))
}


// 卡片版本号来自编译期宏（读 cjpm.toml 的 package.version），不是源码里的字面量：
// cjpm ws bump/sync 物化版本后自动跟进，避免"清单已升版、卡片仍报旧版本"的不一致。
@Test
func atelierA2aVersion_comesFromManifestNotSource() {
    // 非兜底值 —— 只有宏真的读到了清单才会成立
    @Expect(AtelierA2aVersion != "0.0.0", true)
    @Expect(AtelierA2aVersion.size > 0, true)
    // 形如 x.y.z
    @Expect(AtelierA2aVersion.contains("."), true)
}
