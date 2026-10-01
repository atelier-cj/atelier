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
