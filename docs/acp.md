# ACP 接入（Agent 侧）

Atelier 实现 [Agent Client Protocol (ACP) v1](https://agentclientprotocol.com/protocol/v1/overview) 的 **Agent 侧（服务端）**：
以子进程方式被任意 ACP Client（Zed、opencode、JetBrains 等编辑器/宿主）拉起，通过 stdio 完成
`initialize → session/new → session/prompt → 流式 session/update → cancel` 等全生命周期交互。
协议层复用 `acp` 包（[acp-cj](../acp-cj)），Atelier 侧负责把 AgentRuntime / 会话持久化 / 信任闸门接入其回调。

## 快速开始

```bash
# 1. 构建
eval "$(cjvs env zsh)" && eval "$(cjvs stdx-env zsh)"
cjpm build -j 16

# 2. 启动（stdio 服务，阻塞；agent 在启动时选择，默认 default）
cli.app acp [agent]
```

**Zed 配置示例**（`settings.json`）：

```json
{
  "agent": {
    "command": "atelier",
    "args": ["acp"],
    "env": { "HOME": "/home/you" }
  }
}
```

**opencode / 其它宿主**：把 agent 命令配置为 `cli.app acp` 即可。stdout 只输出 ACP 帧，
日志/诊断一律走 stderr（stdout 污染会导致协议错乱）。

## 能力矩阵

| ACP 能力 | 支持 | 说明 |
|---|---|---|
| `initialize`（版本/能力协商） | ✅ | `agentInfo=atelier`；client 能力被记录（`clientCapabilities`），用于 config options 下发判定 |
| `session/new` | ✅ | 建映射（ACP id ↔ atelier 会话 id，JSON 持久化）+ 下发初始 config options |
| `session/prompt` | ✅ | 文本 prompt → atelier 回合；流式 `agent_message_chunk`（带 messageId）、`tool_call` / `tool_call_update`、`usage_update` |
| `session/cancel` / `$/cancel_request` | ✅ | 协作式取消：中断回合尽快返回 `cancelled`（正在执行的工具不强杀） |
| `session/close` | ✅ | 取消在跑回合、清运行态；映射保留供 load/resume |
| `additionalDirectories`（附加工作区） | ✅ | session/new 附加目录 → 会话级预信任（副作用工具直放行；cwd 维持审批） |
| `session/list` | ✅ | 列出该 agent 全部已记录会话（含跨进程） |
| `session/load` | ✅ | 恢复映射并**重放历史**（user/assistant/tool chunks 按序） |
| `session/resume` | ✅ | 恢复不重放，可直接续聊 |
| `session/delete` | ✅ | 删映射 + 连带删除 atelier 会话；其后 prompt 该 id 回错误 |
| `session/set_config_option` | ✅ | 见下「Session Config Options」 |
| `session/set_mode` | ❌ | 旧 Modes API 未实现（config options 已覆盖；支持 config options 的 Client 会忽略 modes） |
| `authenticate` / `logout` | ❌（默认关） | 协议级认证未启用（`authRequired=false`） |
| `session/request_permission`（Agent→Client） | ✅ | 信任闸门 `NeedsApproval` → 授权弹窗（allow once / always / deny）；10 分钟等待 |
| `terminal/*` `fs/*`（Agent→Client） | ❌ | 未使用（atelier 工具在本地执行，不委托 Client 侧能力） |
| `elicitation/create`（form） | ✅ | client 声明 form 时 `ask_user` 工具经单字段表单向用户提问（accept 答案回流回合；decline/cancel/未声明 → 拒绝语义）；URL 模式未启用（无敏感采集场景） |
| prompt 图片/音频/内嵌上下文 | ❌ | 未声明（`promptCapabilities` 默认 false，Client 不会发送） |
| MCP over ACP（宿主代管） | ✅ | `session/new.mcpServers` → McpManager 注册（与本地 `[[mcpServer]]` 并集、同 on-demand 门控；stdio/streamable-http 形态；stdio env 支持 `env` 注入；sse 形态不支持） |

## 概念映射（ACP ↔ Atelier）

| ACP | Atelier |
|---|---|
| ACP sessionId（`sess_*`） | 会话映射 key（持久化于 `<sessionDir>/acp-sessions.json`） |
| atelier 会话 | `SessionStore`（bstorm 持久化，树形消息）——映射记录 `backendSessionId` |
| `session/new.cwd` | `SessionEnvironment.directory`（工具工作目录 + AGENTS.md 注入） |
| prompt 文本（ContentBlock） | `UserMessage` → `AgentRuntime.chatWithSessionId` |
| `session/update` 通知 | `AcpTranslator`：运行时事件 → 协议 update（文本 chunk / tool_call / usage） |
| 回合结束 | `PromptResponse.stopReason`（`end_turn / max_tokens / refusal / cancelled`） |
| 工具授权 | 信任闸门 → `session/request_permission`（`toolApprovalFn` 挂载点） |

## Session Config Options

会话级可调配置通过 ACP 标准 config options 暴露（Client 原生渲染切换 UI）：

- `model`（`select`，`category: "model_config"`，渲染在模型选择器旁）：
  候选 = AgentRegistry 各 agent 出现过的模型 ∪ `ModelContextRegistry` 已知模型（去重），
  默认值 = 当前 agent 配置的模型
- `compaction`（`boolean`）：上下文压缩开关

语义：`session/new` 响应下发初始列表——Client 显式声明 `session.configOptions` 时下发；
**Client 完全没声明 session 能力时也下发**（"未知"不等于"不支持"：只声明 `fs`/`terminal`/`auth`
的 Client 同样可能依赖 config options 选模型）；仅当 Client 声明了 `session` 但明确不含
`configOptions` 时才不下发。修改经
`session/set_config_option`（非法 id/值回 `-32602`），响应回完整最新列表；覆盖**只作用于该 ACP 会话**
（每回合合成生效 config，不改全局 agent 配置）；进程重启后恢复默认。

## 配置与环境

| 配置来源 | 说明 |
|---|---|
| `~/.atelier.toml` | agent/provider/mcpServer 与各形态一致（`cli.app acp` 走同一加载） |
| `cli.app acp [agent]` | **多 agent：启动时选择**（默认 `default`），运行期一个进程服务一个 agent，不做跨会话动态切换 |
| `ATELIER_PROVIDER=echo` | 离线调试/e2e：`EchoProvider` 直接回显最后一条用户消息（不连真实 LLM） |
| `ATELIER_ECHO_DELAY_MS` | echo 延时（毫秒），用于 cancel 路径验证 |
| 会话数据 | `~/.atelier/sessions/`（atelier 会话 + `acp-sessions.json` 映射） |

## 离线验证

```bash
# 全生命周期线协议 e2e（38 断言，无需 LLM/网络）
python3 scripts/acp_e2e.py

# 冒烟：用 acp-cj 的真实 ACP client 拉起
(cd ../acp-cj && HOME=$(mktemp -d) ATELIER_PROVIDER=echo \
  ./target/release/bin/acp.examples.testclient \
  "$(pwd)/target/release/bin/atelier.cli acp" /tmp "你好")
```

## 已知边界

- 取消为协作式：正在执行的工具不强制中断，取消延迟上界 ≈ 当前工具最长执行时间 + 轮询间隔
- `ask_user` 走 Elicitation 表单（单字段）；需要结构化多字段采集可扩展 schema（工具层暂未暴露多字段参数）
- 会话映射的 config options 覆盖状态不跨进程持久化（重连后恢复 agent 默认）
- `session/list` 不带 title/updatedAt 元数据（可选字段）
- 协议层演进：ACP v1 稳定；v2（2026-07 Draft）不追，官方要求 v1/v2 并行期以 v1 为主
