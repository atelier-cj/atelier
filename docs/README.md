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
| [集成指南](integration.md) | 5 种场景：库 / HTTP 挂载 / 独立服务 / CLI / Docker |
| [配置参考](configuration.md) | TOML 配置 + AgentConfig 所有字段 |

## 核心概念

| 文档 | 说明 |
|------|------|
| [消息模型](messages.md) | Message 密封接口 + 4 种角色 + ContentBlock |
| [事件流](events.md) | AgentEvent 密封接口 + 11 种事件 |
| [工具开发](tools.md) | Tool 接口 + 内置工具 + MCP 工具 + Agent-as-Tool |
| [Provider](providers.md) | Provider 接口 + OpenAI 实现 |

## 进阶功能

| 文档 | 说明 |
|------|------|
| [会话管理](sessions.md) | 树形数据模型 + bstorm 持久化 |
| [信任闸门](trust.md) | 目录级权限 + ask_user 确认 |
| [Skill](skills.md) | 声明式技能注入（AgentSkills 规范） |
| [上下文压缩](context.md) | Token 估算 + 自动摘要 |

## 接口参考

| 文档 | 说明 |
|------|------|
| [HTTP API](http-api.md) | 全部端点 + curl 示例 |
| [CLI 参考](cli.md) | serve / repl / run 子命令 |

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
