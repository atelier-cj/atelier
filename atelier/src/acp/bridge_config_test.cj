package atelier.acp

import std.collection.*
import acp.types.{ClientCapabilities, ClientSessionCapabilities, EmptyCapability,
    SessionConfigOptionsCapabilities, SessionConfigOption}

// 门控测试用的模型候选（与 config_options_test.cj 的同名工具函数分开命名，避免包内重名）
func modelOptionsForBridge(): ArrayList<String> {
    let m = ArrayList<String>()
    m.add("deepseek-chat")
    m.add("gpt-4o")
    m
}

// Client 完全没声明 session 能力（只声明 fs/terminal/auth 的 Client 属此类）：
// 「未知」不等于「不支持」，仍须下发 config options，否则对方拿不到任何模型选择机制。
@Test
public func shouldSendConfigOptions_undeclaredSessionStillSends() {
    let caps = ClientCapabilities()
    @Expect(caps.session.isNone(), true)
    @Expect(shouldSendConfigOptions(caps), true)
}

// 显式声明支持 session.configOptions → 下发。
@Test
public func shouldSendConfigOptions_declaredSupportSends() {
    let caps = ClientCapabilities()
    let session = ClientSessionCapabilities()
    session.configOptions = Some(SessionConfigOptionsCapabilities())
    caps.session = Some(session)
    @Expect(shouldSendConfigOptions(caps), true)
}

// 声明了 session 但明确不含 configOptions → 尊重显式声明，不下发。
@Test
public func shouldSendConfigOptions_declaredWithoutConfigOptionsSuppresses() {
    let caps = ClientCapabilities()
    caps.session = Some(ClientSessionCapabilities())
    @Expect(shouldSendConfigOptions(caps), false)
}

// ---- boolean 型 config option 的能力门控（ACP-CONFIG-003）----

func optionIds(options: ArrayList<SessionConfigOption>): ArrayList<String> {
    let ids = ArrayList<String>()
    for (o in options) { ids.add(o.id) }
    ids
}

// Client 完全没声明 session 能力：select（模型）照常下发——它是 config options 的基本形态；
// boolean 不下发——乐观下发只对 select 成立。
@Test
public func visibleConfigOptions_undeclaredSessionSendsSelectOnly() {
    let co = AcpConfigOptions(modelOptionsForBridge(), "gpt-4o", true)
    let ids = optionIds(visibleConfigOptions(co.optionList(), ClientCapabilities()))
    @Expect(ids.size, 1)
    @Expect(ids[0], "model")
}

// 声明了 session.configOptions 但没声明 boolean：同样只下发 select
@Test
public func visibleConfigOptions_configOptionsWithoutBooleanSendsSelectOnly() {
    let caps = ClientCapabilities()
    let session = ClientSessionCapabilities()
    session.configOptions = Some(SessionConfigOptionsCapabilities())
    caps.session = Some(session)
    let co = AcpConfigOptions(modelOptionsForBridge(), "gpt-4o", true)
    let ids = optionIds(visibleConfigOptions(co.optionList(), caps))
    @Expect(ids.size, 1)
    @Expect(ids[0], "model")
}

// 显式声明 configOptions.boolean → 完整列表（含 compaction）
@Test
public func visibleConfigOptions_booleanDeclaredSendsAll() {
    let caps = ClientCapabilities()
    let session = ClientSessionCapabilities()
    let co = SessionConfigOptionsCapabilities()
    co.boolean = Some(EmptyCapability())
    session.configOptions = Some(co)
    caps.session = Some(session)
    let options = AcpConfigOptions(modelOptionsForBridge(), "gpt-4o", true).optionList()
    let sent = visibleConfigOptions(options, caps)
    @Expect(sent.size, 2)
    @Expect(optionIds(sent)[1], "compaction")
    // 不改写入参：原始列表仍是完整的
    @Expect(options.size, 2)
}
