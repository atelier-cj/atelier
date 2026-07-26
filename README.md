# Atelier — 开箱即用的 Agent 运行时

Atelier 是一个纯仓颉实现的 Agent 运行时，定位为**成品工坊**而非**编排框架**——挂载工具、配置 Skills、选择存储，即可获得完整的可运行 Agent，无需从零实现推理循环、上下文管理或模型适配。

## 特性

- **开箱即用**：库 + HTTP 服务 + CLI 三种形态
- **运行时动态**：Agent 在运行时通过 TOML 或代码定义，无需编译
- **多模型**：OpenAI 兼容 API（直接 REST），覆盖绝大多数国产模型
- **MCP 工具**：通过 `ystyle::mcp` 接入任意 MCP 服务器（stdio/Streamable HTTP）
- **树形会话**：Entry + ParentID 树模型，支持 fork/clone/JSONL 持久化
- **信任闸门**：目录级权限控制，`Undecided` 时自动 ask_user 确认
- **Skill 系统**：按 AgentSkills 规范的声明式技能注入
- **上下文压缩**：provider 报告用量 + 本地估算双策略
- **钩子系统**：6 个生命周期钩子（beforeRun~afterTool）
- **Agent-as-Tool**：子 Agent 委派模式，同进程隔离上下文

## 安装

```bash
git clone https://github.com/anomalyco/atelier
cd atelier
eval "$(cjvs env zsh)" && eval "$(cjvs stdx-env zsh)"
cjpm build -j 16
```

## 快速开始

```bash
# 写入环境变量
export OPENAI_API_KEY="sk-xxx"
export OPENAI_BASE_URL="https://api.openai.com/v1"

# 交互式 REPL
atelier repl

# 单次对话
atelier run "你好，介绍一下你自己"

# 启动 HTTP 服务
atelier serve 8080

# 调用 API
curl http://localhost:8080/agent/run \
  -H "Content-Type: application/json" \
  -d '{"agent":"default","messages":[{"role":"user","content":"你好"}]}'
```

## 配置

写入 `~/.atelier.toml`：

```toml
[[provider]]
name = "default"
baseURL = "https://api.openai.com/v1"
apiKey = "${OPENAI_API_KEY}"

[[agent]]
name = "assistant"
model = "gpt-4o"
systemPrompt = "你是一个有用的助手"
tools = ["bash", "read_file", "grep", "glob"]

[logging]
level = "info"

[[mcpServer]]
name = "playwright"
transport = "stdio"
command = "npx @playwright/mcp"
```

## 文档

| 文档 | 说明 |
|------|------|
| [快速开始](docs/getting-started.md) | 5 分钟内跑通 |
| [配置参考](docs/configuration.md) | TOML 配置 + AgentConfig 字段 |
| [消息模型](docs/messages.md) | 4 种角色 + ContentBlock |
| [事件流](docs/events.md) | 11 种事件 + EventStream |
| [工具开发](docs/tools.md) | 内置工具 + 自定义 + MCP |
| [Provider](docs/providers.md) | OpenAI / 自定义 Provider |
| [会话管理](docs/sessions.md) | 树模型 + 持久化 |
| [信任闸门](docs/trust.md) | 权限控制 |
| [Skill](docs/skills.md) | 声明式技能注入 |
| [HTTP API](docs/http-api.md) | 端点参考 + curl 示例 |
| [CLI 参考](docs/cli.md) | serve/repl/run |
| [架构设计](docs/design.md) | 总体设计文档 |

## 开发

```bash
# 编译
cjpm build -j 16

# 运行所有测试
cjpm test -j 16 --no-progress

# 运行单个测试
cjpm test --show-all-output --filter 'TestName.*'
```

## 外部依赖

| 依赖 | 用途 | 协议 |
|------|------|------|
| `ystyle::mcp` | MCP 协议层（工具发现/调用/传输） | MIT |
| `bstorm` | 会话持久化（基于 badger-cj 的 ORM） | MIT |
| `tomlcj` | TOML 解析 | MIT |

核心运行时（Agent Loop、事件流、上下文压缩、Provider、信任闸门）全部自研，零外部依赖。
