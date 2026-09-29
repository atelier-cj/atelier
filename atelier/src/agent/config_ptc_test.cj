package atelier.agent

import std.collection.*
import jsonvalue.*
import atelier.util.{toJsonString, fromJsonString}
import atelier.ptc.ToolPresentationMode

/**
 * AgentConfig 的 PTC 配置项测试：默认值、JSON 往返与向后兼容。
 */
@Test
func config_ptcDefaults() {
    let cfg = AgentConfig.default()
    // 默认保持现网行为：呈现模式为 native，PTC 参数只作为缺省值存在
    @Assert(cfg.toolPresentation.toString() == "native")
    @Expect(cfg.ptcTimeoutSeconds, UInt32(30))
    @Expect(cfg.ptcMaxSubCalls, UInt32(64))
}

@Test
func config_ptcFieldsRoundTrip() {
    let cfg = AgentConfig(
        "ptc-agent", None, "", None, "gpt-4o", None,
        ArrayList<String>(), ArrayList<String>(), Int64(0),
        UInt32(20), Float32(0.7), UInt32(4096), None,
        true, UInt32(16384), UInt32(20000), None, UInt32(50), UInt32(30), UInt32(0),
        ArrayList<String>(), None, Int64(0), Int64(0),
        toolPresentation: ToolPresentationMode.Ptc,
        ptcTimeoutSeconds: UInt32(45),
        ptcMaxSubCalls: UInt32(12))

    let text = toJsonString(cfg)
    @Assert(text.contains("\"toolPresentation\""))
    @Assert(text.contains("\"ptc\""))

    let back = fromJsonString<AgentConfig>(text)
    @Assert(back.toolPresentation.toString() == "ptc")
    @Expect(back.ptcTimeoutSeconds, UInt32(45))
    @Expect(back.ptcMaxSubCalls, UInt32(12))
}

@Test
func config_bothModeRoundTrip() {
    let cfg = AgentConfig(
        "both-agent", None, "", None, "gpt-4o", None,
        ArrayList<String>(), ArrayList<String>(), Int64(0),
        UInt32(20), Float32(0.7), UInt32(4096), None,
        true, UInt32(16384), UInt32(20000), None, UInt32(50), UInt32(30), UInt32(0),
        ArrayList<String>(), None, Int64(0), Int64(0),
        toolPresentation: ToolPresentationMode.Both)

    let back = fromJsonString<AgentConfig>(toJsonString(cfg))
    @Assert(back.toolPresentation.toString() == "both")
}

@Test
func config_missingPtcFieldsKeepDefaults() {
    // 旧配置（没有这三个字段）必须照常加载，落到默认值而不是报错
    let legacy = """
{"name":"old","systemPrompt":"","model":"gpt-4o","maxTurns":20,
"temperature":0.7,"maxOutputTokens":4096,"compactionEnabled":true,
"compactionReserveTokens":16384,"keepRecentTokens":20000,
"maxToolCalls":50,"toolTimeout":30,"minToolInterval":0,
"createdAt":0,"updatedAt":0}"""
    let cfg = fromJsonString<AgentConfig>(legacy)
    @Expect(cfg.name, "old")
    @Assert(cfg.toolPresentation.toString() == "native")
    @Expect(cfg.ptcTimeoutSeconds, UInt32(30))
    @Expect(cfg.ptcMaxSubCalls, UInt32(64))
}

@Test
func config_unknownPresentationFallsBackToNative() {
    // 拼写错误退化为「保持现状」，不让整个 Agent 起不来
    @Assert(ToolPresentationMode.fromString("ptc").toString() == "ptc")
    @Assert(ToolPresentationMode.fromString("both").toString() == "both")
    @Assert(ToolPresentationMode.fromString("native").toString() == "native")
    @Assert(ToolPresentationMode.fromString("PTC").toString() == "native")
    @Assert(ToolPresentationMode.fromString("").toString() == "native")
    @Assert(ToolPresentationMode.fromString("nonsense").toString() == "native")
}
