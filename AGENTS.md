# Atelier — 可嵌入的 Agent Harness

## 仓颉语言

- 语法问题使用 `cangjie_docs` 相关工具在文档中查找，不要猜 API 和语法
- 在提示语法错误时使用 `cangjie-mem` 加载语言级记忆
- `match` 的 `case` 后不能接 `{}`，case 后直接写多行表达式
- 有固定结构的类不要使用jsonvalue手动解析，实现json.stream的序列化接口
- 除非实在没固定结构的类，否则禁止使用jsonvalue动态获取

## 任务指南

- **不要考虑时间，不要简化算法，不要简化测试，这项目是自己的产品，按最好的来搞**
- 新功能必须写单元测试，以仓颉单元测试为主
- 测试发现的新问题需要解决，且要添加新用例到单元测试里
- 不要在项目外创建仓颉单文件测试，非 cjpm 项目没法导入当前项目
- 有单元测试后再提交

## Git 分支流程

- **开发一律开功能分支**，不在 master 上直接开发：`git checkout -b feat/<feature-name>`
- 分支命名：`feat/<功能名>`（新功能）/ `fix/<缺陷名>`（修复）
- 每个任务完成后独立提交（遵循「有单元测试后再提交」），允许分支内多次提交
- 功能完成后：合并回 master，并删除已合并的分支
- 合并方式：优先 `git merge --no-ff`（保留分支历史）或 `git rebase` 后快进合并，二选一即可
- 每次开工前先 `git pull` 同步远程

## 常用命令

需先加载 cjvs 环境：

```shell
eval "$(cjvs env zsh)" && eval "$(cjvs stdx-env zsh)"
```

```shell
# 编译
cjpm build -j 16

# 运行所有测试
cjpm test -j 16 --no-progress

# 运行指定测试（--filter 是【通配符】不是正则：* 匹配任意字符）
#   注意：本仓测试是顶层函数风格（如 runtime_ptcModeExposesOnlyRunXisp），用例名里没有点，
#   因此 '.*' 选不中任何用例——那是 class 风格的写法（类名.方法名）。
cjpm test --show-all-output --filter '*keyword*'     # 子串匹配（最常用）
cjpm test --show-all-output --filter 'runtime_ptc*'  # 前缀匹配

# 清理构建缓存
cjpm clean
```

## LSP 报错

如果代码看起来没错但 LSP 报错：

- 源码文件：执行 `cjpm build` 编译
- 测试文件：执行 `cjpm test --no-run` 编译

## 外部依赖

| 依赖 | 用途 | 说明 |
|------|------|------|
| `ystyle::mcp` | MCP 协议层 | 工具发现/调用/传输；注册表 2.3.15（stdlibio env/args 完整注入） |
| `llm_api` | 消息 / 事件 / Provider 类型层 | 跨产品共享的公共类型与 REST+SSE 的 Provider 实现；本仓只 `public import` 再导出并扩展 |
| `bstorm` | 会话持久化 | 基于 badger-cj 的 ORM 库 |
| `acp` | ACP v1 协议层 | 注册表 0.2.6（Agent/Client 双端，acp-cj） |
| `ystyle::xisp` | PTC 程序执行引擎 | 注册表 0.4.1（`registerPure` 纯函数子集 / 求值中断检查点 / 严格解析；此前为本地 path 依赖） |
| `tomlcj` | TOML 配置装载 | `atelier.config` 的 Agent / Provider 配置模型；下游宿主与 `server` 共用同一套 |
| `ystyle::jsonrpc` | JSON-RPC 传输 | 0.7.8；MCP 传输侧依赖 |

## 项目结构

```
atelier/                     # 仓库根 = cjpm 工作区（[workspace]，产品版本见 workspace.toml）
├── AGENTS.md                # 本文件
├── cjpm.toml                # 工作区清单：members = [atelier, server, cli] + 共享平台配置
├── workspace.toml           # cjpm-ws 产品清单（lockstep 版本 / 发布范围）
├── target/                  # 工作区共享产物目录（cjpm build 输出：target/release/bin/cli.app）
├── atelier/                 # 核心库成员（包名 atelier）
│   ├── cjpm.toml
│   └── src/
│       ├── message/         # 消息模型（地基，零外部依赖）
│       ├── agent/           # Agent 配置/运行时/事件
│       ├── tool/            # Tool 接口 + 内置工具 + MCP 适配
│       ├── provider/        # Provider 类型再导出（REST+SSE 的实现在 llm_api）
│       ├── config/          # TOML 配置模型（Agent / Provider / 信任 / 压缩）
│       ├── session/         # 会话模型 + 存储（内存/bstorm）
│       ├── context/         # 上下文压缩
│       ├── trust/           # 信任闸门
│       ├── acp/             # ACP v1 Agent 侧适配（translator/映射/config options/bridge）
│       ├── skill/           # Skill 系统（Phase 3）
│       ├── ptc/             # PTC 程序化工具调用
│       └── util/
├── server/                  # HTTP 服务成员（包名 server）
├── cli/                     # CLI 成员（包名 cli）
├── docs/                    # 设计文档
│   ├── design.md            # 总体设计
│   └── plans/               # 实现计划
└── scripts/                 # e2e / 辅助脚本
```

> 工作区语义：根目录 `cjpm build` / `cjpm clean` / `cjpm test` 一条命令覆盖三个成员
> （不必逐个进成员目录）；成员间依赖写**版本号**（`atelier = "0.1.0"`），由工作区本地解析，不用
> path 依赖。共享的 `[target.*]`（stdx 二进制依赖、`-luring` / `-lcrypt32` 链接项）集中在根 `cjpm.toml`。


## 核心设计决策

- **装配束（HarnessSpec）**：组件一次装配，`AgentRuntime(spec, cfg)` 是**唯一**构造；`with*` 派生
  是值语义（不动共享组件），run 作用域的工具叠加走 `ToolRegistry.derived` 视图而不是复制表
- **依赖边界**：协议与共享类型用现成库（`ystyle::mcp` 工具协议、`llm_api` 消息/事件/Provider 类型与
  REST+SSE 实现、`acp` ACP v1、`ystyle::jsonrpc` 传输），会话存储用 `bstorm`；Agent 循环 / 工具 /
  压缩 / 会话树自研
- **运行时动态**：Agent 通过 JSON/YAML 在运行时定义，不依赖编译期宏
- **消息密封接口**：4 种角色（User/Assistant/ToolResult/Compaction），通过 `role()` 判别
- **树形会话**：Entry + ParentID 链，支持 fork/clone，JSONL 持久化
- **两阶段压缩**：Provider 报告用量优先，本地估算兜底
- **配置模型在核心**：`atelier.config`（TOML）是 Agent / Provider / 信任 / 压缩配置的唯一来源，
  `server` 只再导出 —— 宿主与下游从核心取用，不必依赖 `server` 成员
