package atelier.agent

import atelier.provider.*

// 请求级中间件：包住 Provider 的 chat/chatStreaming 链（模型请求重试/路由/限流/观测/缓存等）。
// Hook 是 run/turn/tool 粒度，管不到单次模型请求——本中间件补上请求级缺口。
// 注入：AgentRuntime / SessionLoop 构造 middlewares（按序 wrap，先注入者最外层）；
// 默认空列表 = 零行为变化。实现：返回一个包装 Provider（内部委托原 provider）。
public interface ProviderMiddleware {
    func wrap(provider: Provider): Provider
}
