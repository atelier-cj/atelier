package server

import stdx.net.http.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

class NullHandler <: HttpRequestHandler {
    public func handle(ctx: HttpContext): Unit {}
}

// 空路径族：既有服务全部走精确注册，A2A 按路径族整体接管。
func a2aPaths(): ArrayList<String> {
    ArrayList<String>(["/", "/.well-known/agent-card.json", "/message:send",
        "/message:stream", "/tasks", "/tasks/", "/extendedAgentCard"])
}

@Test
public func mountedDistributor_exactWinsOverMounted() {
    let d = MountedDistributor()
    d.register("/agent/run", NullHandler())
    d.mount(a2aPaths(), NullHandler())

    // 精确注册的路由不被挂载服务抢走
    @Expect(d.routeLabel("/agent/run"), "exact")
    @Expect(d.routeLabel("/session/load"), "none")
}

@Test
public func mountedDistributor_coversA2aPathsIncludingParameterized() {
    let d = MountedDistributor()
    d.register("/health", NullHandler())
    d.mount(a2aPaths(), NullHandler())

    @Expect(d.routeLabel("/"), "mounted")
    @Expect(d.routeLabel("/.well-known/agent-card.json"), "mounted")
    @Expect(d.routeLabel("/message:send"), "mounted")
    @Expect(d.routeLabel("/tasks"), "mounted")
    // 带参路径靠前缀命中 —— 精确匹配表达不了
    @Expect(d.routeLabel("/tasks/abc"), "mounted")
    @Expect(d.routeLabel("/tasks/abc:cancel"), "mounted")
    @Expect(d.routeLabel("/extendedAgentCard"), "mounted")
    // 前缀不越界：/tasks 的前缀不命中 /tasksX
    @Expect(d.routeLabel("/tasksX"), "none")
    // 其它 well-known 路径不被 A2A 接管
    @Expect(d.routeLabel("/.well-known/other.json"), "none")
}

@Test
public func mountedDistributor_withoutMountFallsBackToNotFound() {
    let d = MountedDistributor()
    d.register("/health", NullHandler())
    @Expect(d.hasMounted(), false)
    @Expect(d.routeLabel("/tasks"), "none")
    @Expect(d.routeLabel("/health"), "exact")
}

@Test
public func mountedDistributor_registerLambdaIsDispatchable() {
    let d = MountedDistributor()
    d.register("/agent/config", { _ => () })
    @Expect(d.routeLabel("/agent/config"), "exact")
}
