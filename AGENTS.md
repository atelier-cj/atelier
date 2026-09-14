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

# 运行指定测试
cjpm test --show-all-output --filter 'TestName.*'

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
| `ystyle::mcp` | MCP 协议层 | 工具发现/调用/传输；注册表 2.3.7（stdlibio env/args 完整注入） |
| `bstorm` | 会话持久化 | 基于 badger-cj 的 ORM 库 |
| `acp` | ACP v1 协议层 | 注册表 0.2.2（Agent/Client 双端，acp-cj） |

## 项目结构

```
atelier/
├── AGENTS.md          # 本文件
├── cjpm.toml          # 包管理配置
├── docs/              # 设计文档
│   ├── design.md      # 总体设计
│   └── plans/         # 实现计划
├── src/
│   ├── message/       # 消息模型（地基，零外部依赖）
│   ├── agent/         # Agent 配置/运行时/事件
│   ├── tool/          # Tool 接口 + 内置工具 + MCP 适配
│   ├── provider/      # LLM Provider 接口 + OpenAI 实现
│   ├── session/       # 会话模型 + 存储（内存/bstorm）
│   ├── context/       # 上下文压缩
│   ├── trust/         # 信任闸门
│   ├── acp/           # ACP v1 Agent 侧适配（translator/映射/config options/bridge）
│   ├── skill/         # Skill 系统（Phase 3）
│   ├── server/        # HTTP 服务（Phase 2）
│   └── cli/           # CLI 入口（Phase 3）
```

## 核心设计决策

- **自研优先**：除 MCP 协议（`ystyle::mcp`）和会话存储（`bstorm`）外，全部自研
- **运行时动态**：Agent 通过 JSON/YAML 在运行时定义，不依赖编译期宏
- **消息密封接口**：4 种角色（User/Assistant/ToolResult/Compaction），通过 `role()` 判别
- **树形会话**：Entry + ParentID 链，支持 fork/clone，JSONL 持久化
- **两阶段压缩**：Provider 报告用量优先，本地估算兜底
- **直接对接 REST**：Provider 直接实现 HTTP + SSE，不通过 MCP 代理 LLM
