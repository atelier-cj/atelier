package cli

import atelier.trust.*
import std.collection.*

func newRegistry(): SlashCommandRegistry {
    SlashCommandRegistry(TrustManager())
}

@Test
func slash_help() {
    let r = newRegistry()
    match (r.dispatch("/help")) {
        case Some(s) =>
            @Expect(s.contains("Available commands"), true)
            @Expect(s.contains("/trust"), true)
            @Expect(s.contains("/exit"), true)
        case None => @Fail("expected help text")
    }
}

@Test
func slash_nonSlashLineReturnsNone() {
    let r = newRegistry()
    match (r.dispatch("hello")) {
        case Some(_) => @Fail("expected None for non-slash line")
        case None => ()
    }
    match (r.dispatch("")) {
        case Some(_) => @Fail("expected None for empty line")
        case None => ()
    }
}

@Test
func slash_unknownCommand() {
    let r = newRegistry()
    match (r.dispatch("/nosuch")) {
        case Some(s) =>
            @Expect(s.contains("Unknown command"), true)
            @Expect(s.contains("nosuch"), true)
        case None => @Fail("expected unknown command message")
    }
}

@Test
func slash_trustNoArg() {
    let r = newRegistry()
    match (r.dispatch("/trust")) {
        case Some(s) => @Expect(s.contains("Usage: /trust"), true)
        case None => @Fail("expected usage message")
    }
}

@Test
func slash_trustArg() {
    let r = newRegistry()
    match (r.dispatch("/trust /tmp/proj")) {
        case Some(s) => @Expect(s.contains("Trusted: /tmp/proj"), true)
        case None => @Fail("expected trusted message")
    }
}

@Test
func slash_untrustArg() {
    let r = newRegistry()
    match (r.dispatch("/untrust /tmp/proj")) {
        case Some(s) => @Expect(s.contains("Untrusted: /tmp/proj"), true)
        case None => @Fail("expected untrusted message")
    }
}

@Test
func slash_session() {
    let r = newRegistry()
    match (r.dispatch("/session")) {
        case Some(s) => @Expect(s.contains("Session"), true)
        case None => @Fail("expected session info")
    }
}

@Test
func slash_exitAndQuit() {
    let r = newRegistry()
    @Expect(r.dispatch("/exit"), Some("exit"))
    @Expect(r.dispatch("/quit"), Some("exit"))
}

@Test
func slash_clear() {
    let r = newRegistry()
    match (r.dispatch("/clear")) {
        case Some(s) => @Expect(s.contains("Conversation cleared"), true)
        case None => @Fail("expected clear message")
    }
}

@Test
func slash_registerAndHas() {
    let r = newRegistry()
    r.register("ping", "ping test", { args => "pong" })
    @Expect(r.has("ping"), true)
    @Expect(r.has("nosuch"), false)
    match (r.dispatch("/ping")) {
        case Some(s) => @Expect(s, "pong")
        case None => @Fail("expected pong from custom command")
    }
}

// ── /subagent start 参数解析 ──

@Test
func parseSubStartArgs_local() {
    let parts: Array<String> = ["/subagent", "start", "helper", "你好"]
    let (remote, agent, prompt) = parseSubStartArgs(parts)
    @Expect(remote, false)
    @Expect(agent, "helper")
    @Expect(prompt, "你好")
}

@Test
func parseSubStartArgs_remote() {
    let parts: Array<String> = ["/subagent", "start", "--remote", "helper", "远程", "你好", "世界"]
    let (remote, agent, prompt) = parseSubStartArgs(parts)
    @Expect(remote, true)
    @Expect(agent, "helper")
    @Expect(prompt, "远程 你好 世界")
}

@Test
func parseSubStartArgs_missingAgent() {
    let parts1: Array<String> = ["/subagent", "start"]
    let (r1, a1, _) = parseSubStartArgs(parts1)
    @Expect(r1, false)
    @Expect(a1, "")
    let parts2: Array<String> = ["/subagent", "start", "--remote"]
    let (r2, a2, _) = parseSubStartArgs(parts2)
    @Expect(r2, true)
    @Expect(a2, "")
}

@Test
func parseSubStartArgs_emptyPromptAllowed() {
    let parts: Array<String> = ["/subagent", "start", "helper"]
    let (remote, agent, prompt) = parseSubStartArgs(parts)
    @Expect(remote, false)
    @Expect(agent, "helper")
    @Expect(prompt, "")
}
