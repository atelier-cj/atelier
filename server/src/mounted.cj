package server

import stdx.net.http.*
import std.collection.*

/**
 * 组合分发器：精确注册的既有服务 + 一个「按路径族挂载」的处理器。
 *
 * 为什么需要它：stdx 的 `HttpRequestDistributor.register` 是**精确匹配**，表达不了
 * `/tasks/{id}`、`/tasks/{id}:cancel` 这类带参路径。A2A 端点的路径形态就属于后者，
 * 因此按「路径族」整体转交，族内的精细路由由被挂载的处理器自己完成。
 *
 * 匹配顺序：
 *   1. 精确注册表（既有 `/agent`、`/session`、`/ag-ui`、`/health` 等前缀下的路由）；
 *   2. 挂载路径族（族内命中即整体转交）；
 *   3. 404。
 *
 * 顺序刻意让精确注册优先：新挂服务不该悄悄抢走既有路由。
 *
 * 挂载路径的写法：以 `/` 结尾表示前缀（`/tasks/` 命中 `/tasks/abc:cancel`），
 * 否则是精确路径（`/tasks` 只命中自身）。
 */
public class MountedDistributor <: HttpRequestDistributor {
    private let exact = HashMap<String, HttpRequestHandler>()
    private var mounted: ?HttpRequestHandler = None
    private let mountedPaths = ArrayList<String>()

    public init() {}

    // 挂载一个处理器及其路径族。重复挂载会覆盖前一个处理器（路径族合并）。
    public func mount(paths: ArrayList<String>, handler: HttpRequestHandler): MountedDistributor {
        this.mounted = Some(handler)
        for (p in paths) {
            if (!this.mountedPaths.contains(p)) {
                this.mountedPaths.add(p)
            }
        }
        this
    }

    public func register(path: String, handler: HttpRequestHandler): Unit {
        this.exact[path] = handler
    }

    public func register(path: String, handler: (HttpContext) -> Unit): Unit {
        this.exact[path] = FuncHandler(handler)
    }

    public func distribute(path: String): HttpRequestHandler {
        match (this.exact.get(path)) {
            case Some(h) => return h
            case None => ()
        }
        match (this.mounted) {
            case Some(h) =>
                if (this.matchesMounted(path)) {
                    return h
                }
            case None => ()
        }
        NotFoundHandler()
    }

    private func matchesMounted(path: String): Bool {
        for (p in this.mountedPaths) {
            // 根路径必须按精确处理："/" 也是所有路径的前缀，若当前缀用，
            // 挂载服务会吃掉每一个未精确注册的路径（包括将来新加的路由）。
            if (p == "/") {
                if (path == "/") {
                    return true
                }
            } else if (p.endsWith("/")) {
                if (path.startsWith(p)) {
                    return true
                }
            } else if (path == p) {
                return true
            }
        }
        false
    }

    public func hasMounted(): Bool {
        this.mounted.isSome()
    }

    // 该路径最终由哪一侧接管："exact" | "mounted" | "none"。
    // 供测试断言与启动期路由诊断使用（HttpRequestHandler 是接口，无法直接比较身份）。
    public func routeLabel(path: String): String {
        if (this.exact.contains(path)) {
            return "exact"
        }
        match (this.mounted) {
            case Some(_) =>
                if (this.matchesMounted(path)) {
                    return "mounted"
                }
            case None => ()
        }
        "none"
    }
}
