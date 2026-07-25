package atelier.server

import stdx.net.http.*

public struct ServerMiddleware {
    public let authToken: Option<String>

    public init(authToken: Option<String>) {
        this.authToken = authToken
    }

    public func wrap(handler: (HttpContext) -> Unit): (HttpContext) -> Unit {
        return { ctx =>
            if (let Some(token) <- this.authToken) {
                let auth: ?String = ctx.request.headers.getFirst("authorization")
                if (auth != None) {
                    if (auth != "Bearer " + token) {
                        ctx.responseBuilder.status(UInt16(401)).body("{\"error\":\"unauthorized\"}")
                        return
                    }
                } else {
                    ctx.responseBuilder.status(UInt16(401)).body("{\"error\":\"unauthorized\"}")
                    return
                }
            }
            handler(ctx)
        }
    }
}
