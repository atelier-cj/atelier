package atelier.acp

import std.collection.*
import acp.types.{McpServer, EnvVariable, HttpHeader}

// stdio：type None/stdio + command → transport stdio
@Test
public func acpMcp_stdioMapping() {
    let s = McpServer.stdio("fs", "npx", args: ArrayList<String>(["-y", "x"]))
    let cfg = acpMcpServerToConfig(s)
    @Expect(cfg.isSome(), true)
    let c = cfg.getOrThrow()
    @Expect(c.name, "fs")
    @Expect(c.transport, "stdio")
    @Expect(c.command, "npx -y x")   // args 已拼回 command
}

// http：type http + url + headers → streamable-http + headers
@Test
public func acpMcp_httpMapping() {
    let h = HttpHeader()
    h.name = "Authorization"
    h.value = "Bearer t"
    let hs = ArrayList<HttpHeader>()
    hs.add(h)
    let s = McpServer.http("docs", "https://e.com/mcp", headers: hs)
    let cfg = acpMcpServerToConfig(s)
    @Expect(cfg.isSome(), true)
    let c = cfg.getOrThrow()
    @Expect(c.transport, "streamable-http")
    @Expect(c.url, "https://e.com/mcp")
    match (c.headers.get("Authorization")) {
        case Some(v) => @Expect(v, "Bearer t")
        case None => @Fail("header lost")
    }
}

// sse / 未知形态 / 缺字段 → None（不支持或无效，由调用方记录）
@Test
public func acpMcp_unsupportedShapes() {
    let sse = McpServer()
    sse.name = "x"
    sse.`type` = Some("sse")
    sse.url = Some("https://e.com/sse")
    @Expect(acpMcpServerToConfig(sse).isNone(), true)

    let httpNoUrl = McpServer.http("x", "")
    @Expect(acpMcpServerToConfig(httpNoUrl).isNone(), true)

    let stdioNoCmd = McpServer.stdio("x", "")
    @Expect(acpMcpServerToConfig(stdioNoCmd).isNone(), true)
}

// 名字含下划线：映射层不拦（McpManager 注册层拒绝并告警），此处确认透传
@Test
public func acpMcp_underscoreNamePassesThrough() {
    let s = McpServer.stdio("my_fs", "npx")
    let cfg = acpMcpServerToConfig(s)
    @Expect(cfg.isSome(), true)
    @Expect(cfg.getOrThrow().name, "my_fs")
}

// stdio + env：EnvVariable → cfg.env
@Test
public func acpMcp_stdioEnvMapping() {
    let ev = EnvVariable()
    ev.name = "API_TOKEN"
    ev.value = "secret"
    let evs = ArrayList<EnvVariable>()
    evs.add(ev)
    let s = McpServer.stdio("svc", "server-tool", env: evs)
    let cfg = acpMcpServerToConfig(s)
    @Expect(cfg.isSome(), true)
    let c = cfg.getOrThrow()
    @Expect(c.env.size, 1)
    match (c.env.get("API_TOKEN")) {
        case Some(v) => @Expect(v, "secret")
        case None => @Fail("env lost")
    }
}
