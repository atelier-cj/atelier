package atelier.acp

import acp.types.{ClientCapabilities, ClientSessionCapabilities, EmptyCapability}

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
    session.configOptions = Some(EmptyCapability())
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
