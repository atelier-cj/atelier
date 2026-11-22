# Atelier 文档

```ascii
              Atelier
    ┌─────────────────────┐
    │    Agent Runtime     │
    │  ┌─────────────────┐ │
    │  │ 库 · HTTP · CLI │ │
    │  └─────────────────┘ │
    └─────────────────────┘
```

## 入门

| 文档 | 说明 |
|------|------|
| [集成指南](integration.md) | 快速装配（`Harness.open` / `HarnessSpec`）+ 6 种嵌入场景 + ACP / A2A 两种对外形态 |
| [配置参考](configuration.md) | TOML 配置 + AgentConfig 所有字段 |

## 核心概念

| 文档 | 说明 |
|------|------|
| [消息模型](messages.md) | Message 密封接口 + 4 种角色 + ContentBlock |
| [事件流](events.md) | AgentEvent 密封接口 + 14 种事件（含 Suspend 挂起）+ EventStream |
| [工具](tools.md) | Tool 接口 + 内置工具 + 自定义 + MCP + Agent-as-Tool |
| [Provider](providers.md) | Provider 接口 + OpenAI/Anthropic/Ollama + 上下文窗口 |
| [Hook](hooks.md) | 决策型拦截器：观察/改写/短路 Agent 生命周期 |
| [SDK 可替换点](extensibility.md) | 全部替换点：3 个契约级（信任判定 / 压缩 / 循环）+ 15 个组件级（存储 / Provider / 工具 / 中间件 …） |

## 进阶功能

| 文档 | 说明 |
|------|------|
| [会话管理](sessions.md) | 树形数据模型 + bstorm 持久化 + 导出 |
| [信任闸门](trust.md) | 三态权限 + 目录继承 + 结构化审批提问 |
| [Skill](skills.md) | 声明式技能注入（AgentSkills 规范） |
| [子 Agent](subagents.md) | 可持续子 Agent：双向 send_message、父端调度工具 |

## 接口参考

| 文档 | 说明 |
|------|------|
| [HTTP API](http-api.md) | 全部端点 + curl 示例 |
| [CLI 参考](cli.md) | serve / tui / run / acp / a2a 子命令 + 斜杠命令 |
| [ACP 接入](acp.md) | ACP v1 Agent 侧：能力矩阵、elicitation 提问、接入示例、Session Config Options |
| [A2A 接入](a2a.md) | A2A v1 双向：服务端能力矩阵、概念映射、流式产物语义、远端子 Agent、部署 |

## 架构

| 文档 | 说明 |
|------|------|
| [架构设计](design.md) | 总体设计、路线图、模块依赖 |

## 示例

```bash
examples/
├── data_analyst/       # 数据分析助手
├── customer_service/   # 智能客服
└── code_assistant/     # 代码助手
```
