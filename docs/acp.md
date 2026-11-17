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
| `session/list` | ✅ | 列出已记录会话（含跨进程）；`cwd` 精确过滤（不匹配返回 `sessions: []`）；**不分页**，任何 `cursor` 都回 `-32602` |
| `session/load` | ✅ | 恢复映射并**重放历史**（user/assistant/tool chunks 按序） |
| `session/resume` | ✅ | 恢复不重放，可直接续聊 |
| `session/delete` | ✅ | 删映射 + 连带删除 atelier 会话；其后 prompt 该 id 回错误 |
| `session/set_config_option` | ✅ | 见下「Session Config Options」 |
| `session/set_mode` | ❌ | 旧 Modes API 未实现（config options 已覆盖；支持 config options 的 Client 会忽略 modes） |
| `authenticate` / `logout` | ❌（默认关） | 协议级认证未启用（`authRequired=false`） |
| `session/request_permission`（Agent→Client） | ❌（未使用） | 审批统一走 elicitation 表单，不再反向调用本方法 |
| `terminal/*` `fs/*`（Agent→Client） | ❌ | 未使用（atelier 工具在本地执行，不委托 Client 侧能力） |
| `elicitation/create`（form） | ✅ | client 声明 form 时，审批/选择/表单都经 elicitation 表单向用户提问（每个字段一个字符串 property，候选值写进提示正文）；accept → 答复回流回合，decline/cancel/失败/未声明 → `Cancelled` + 留痕；URL 模式未启用（无敏感采集场景） |
| prompt 图片/音频/内嵌上下文 | ❌ | 未声明（`promptCapabilities` 默认 false，Client 不会发送） |
| MCP over ACP（宿主代管） | ✅ | `session/new.mcpServers` → McpManager **立即连接**并注册（与本地 `[[mcpServer]]` 并集、同 on-demand 门控；stdio/streamable-http 形态；stdio 的 `env` 作为子进程环境注入，不上命令行；sse 形态不支持） |

## 概念映射（ACP ↔ Atelier）

| ACP | Atelier |
|---|---|
| ACP sessionId（`sess_*`） | 会话映射 key（持久化于 `<sessionDir>/acp-sessions.json`） |
| atelier 会话 | `SessionStore`（bstorm 持久化，树形消息）——映射记录 `backendSessionId` |
| `session/new.cwd` | `SessionEnvironment.directory`（工具工作目录 + AGENTS.md 注入） |
| prompt 文本（ContentBlock） | `UserMessage` → `AgentRuntime.chatWithSessionId` |
| `session/update` 通知 | `AcpTranslator`：运行时事件 → 协议 update（文本 chunk / tool_call / usage） |
| 回合结束 | `PromptResponse.stopReason`（`end_turn / max_tokens / refusal / cancelled`） |
| 用户提问 | 结构化提问（审批/选择/表单）→ elicitation 表单（`askFn` 挂载点）；decline/cancel/失败 → `Cancelled` + 留痕 |

## Session Config Options

会话级可调配置通过 ACP 标准 config options 暴露（Client 原生渲染切换 UI）：

- `model`（`select`，`category: "model_config"`，渲染在模型选择器旁）：
  候选 = AgentRegistry 各 agent 出现过的模型 ∪ `ModelContextRegistry` 已知模型（去重），
  默认值 = 当前 agent 配置的模型
- `compaction`（`boolean`）：上下文压缩开关

两层判定（缺一不可）：

1. **整份列表下不下发**（`shouldSendConfigOptions`）：`session/new` 响应下发初始列表——Client 显式声明
   `session.configOptions` 时下发；**Client 完全没声明 session 能力时也下发**（"未知"不等于"不支持"：
   只声明 `fs`/`terminal`/`auth` 的 Client 同样可能依赖 config options 选模型）；仅当 Client 声明了
   `session` 但明确不含 `configOptions` 时才不下发。
2. **单个选项下不下发**（`visibleConfigOptions`，ACP-CONFIG-003）：`boolean` 型（`compaction`）只有在
   Client 声明了 `clientCapabilities.session.configOptions.boolean: {}` 时才能下发——规范是 MUST NOT，
   未声明时下发的唯一结果是被对端判为非法参数。`select`（`model`）不受此门控：它是 config options
   的基本形态，「没声明扩展能力」不影响它。门控对所有出口一致：`session/new` 结果、
   `session/set_config_option` 回包（否则等于换个出口把 boolean 递出去）。

修改经 `session/set_config_option`（非法 id/值回 `-32602`），响应回完整最新列表（同上经门控）；
覆盖**只作用于该 ACP 会话**（每回合合成生效 config，不改全局 agent 配置）；进程重启后恢复默认。

## 配置与环境

| 配置来源 | 说明 |
|---|---|
| `~/.atelier.toml` | agent/provider/mcpServer 与各形态一致（`cli.app acp` 走同一加载） |
| `cli.app acp [agent]` | **多 agent：启动时选择**（默认 `default`），运行期一个进程服务一个 agent，不做跨会话动态切换 |
| `ATELIER_PROVIDER=echo` | 离线调试/e2e：`EchoProvider` 直接回显最后一条用户消息（不连真实 LLM） |
| `ATELIER_ECHO_DELAY_MS` | echo 延时（毫秒），用于 cancel 路径验证 |
| 会话数据 | `~/.atelier/sessions/`（atelier 会话 + `acp-sessions.json` 映射） |

## 离线验证

两层，职责不同，**都要跑**：

| 手段 | 回答什么问题 | 范围由谁定 |
|---|---|---|
| `scripts/acp_e2e.py` | 「atelier 自己定义的行为有没有被改坏」 | 本仓（45 断言，全离线） |
| `scripts/acp_tck.sh` | 「是否符合 ACP v1 协议要求」 | 上游官方 TCK |

```bash
# 1) 本仓线协议 e2e（45 断言，无需 LLM/网络）：initialize / session.new / prompt 流式 / cancel /
#    list(cwd 过滤 + cursor 校验) / load 跨进程重放 / delete / set_config_option /
#    config options 的 boolean 门控 / stdio MCP 真连接（含 env 与「无 env 带参命令」两种形态）
python3 scripts/acp_e2e.py

# 2) 官方一致性套件（agentclientprotocol/acp-tck）：首次运行会克隆到工作区根的 .tmp-acp-tck
scripts/acp_tck.sh                 # 全量；报告落 target/acp-tck-report.json
scripts/acp_tck.sh -k "list or mcp"  # 只跑匹配用例（透传 acp-tck 参数）
```

TCK 的三个前置（脚本已内置默认值，别用裸命令手跑）：

- **`HOME` 必须是可写目录**：脚本默认 `../.tmp-acp-home`（工作区内）。DSH 沙箱下真 `HOME` 里的
  `~/.atelier` 不可写，每个 `session/new` 都会失败——那不是一致性问题，是环境问题。
- **必须给 `ATELIER_ECHO_DELAY_MS`**（默认 1200）：取消类用例需要「回合还在跑」的窗口，
  否则 `ACP-CANCEL-*` 全部 skip。
- **结论以 JSON 报告为准**：`acp-tck` 的 stdout 很长，且「有 SKIP 无 FAIL」也会给
  `NOT CONFORMANT`（未实现的能力按 skip 计）。脚本按报告里的 `requirements[].status` 判失败条数。

TCK 的边界（别把它当「全绿 = 完美」）：

- 它只验**协议要求**，不验 atelier 的业务语义；反过来 `acp_e2e.py` 也不覆盖协议一致性
- 未实现的能力（archive / systemPrompt / modes / auth / 图片音频 prompt …）表现为
  `SKIPPED` 而非 `FAIL`——`SKIPPED` 数量反映「没实现多少扩展」，不是缺陷计数
- 上游 schema 会跟随 ACP Draft 演进；升级 TCK（`git -C .tmp-acp-tck pull`）后历史数字不可比，
  要重新记录基线

```bash
# 冒烟：用 acp-cj 的真实 ACP client 拉起
(cd ../acp-cj && HOME=$(mktemp -d) ATELIER_PROVIDER=echo \
  ./target/release/bin/acp.examples.testclient \
  "$(pwd)/target/release/bin/atelier.cli acp" /tmp "你好")
```

## 已知边界

- 取消为协作式：正在执行的工具不强制中断，取消延迟上界 ≈ 当前工具最长执行时间 + 轮询间隔
- 提问走 Elicitation 的**字符串属性**通道（每字段一个 property，候选 id/说明写进提示正文）：不直接映射 enum/array 属性（构造入口尚未确认）；答复合法性由 runtime 的 `validateAnswer` 把关，字符串通道不会放过非法选项
- 会话映射的 config options 覆盖状态不跨进程持久化（重连后恢复 agent 默认）
- `session/list` 不带 title/updatedAt 元数据（可选字段）；`cwd` 是**精确匹配**（不做前缀/子目录归并），
  因为协议里它就是「按会话工作目录过滤」
- `session/list` **不分页**：响应从不带 `nextCursor`，因此任何 `cursor` 都不是本 Agent 签发过的 →
  一律 `-32602`（忽略它会让 Client 误以为自己拿到的是下一页）
- 宿主下发的 `mcpServers` 是 `command + args` 单串模型：`args` 按**空格**拼接后交给 stdio transport
  （参数里含空格会被拆开），且 `sse` 形态不支持
- stdio MCP 子进程的子进程环境 = **当前进程环境 + 配置里的 `env`（后者优先）**；`env` 只进子进程环境，
  不上命令行（避免密钥出现在 `ps`/argv 里）
- 宿主下发的 `mcpServers` 只在 `session/new` 时注册连接：`session/load` / `session/resume` 请求里
  再带的 `mcpServers` 不会重新注册（同进程内该会话已有连接；跨进程 load 后这些 server 的工具不在表里，
  需要时由本地 `[[mcpServer]]` 配置或新建会话承担）
- 协议层演进：ACP v1 稳定；v2（2026-07 Draft）不追，官方要求 v1/v2 并行期以 v1 为主
