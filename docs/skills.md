# Skill

Skill 是按 [AgentSkills 规范](https://agentskills.io/specification) 定义的声明式技能包，本质是**提示词工程化的最佳实践**。

## 目录结构

```
~/.agents/skills/<name>/
├── SKILL.md           # 必需：YAML frontmatter + Markdown 指令
├── scripts/           # 可选：可执行脚本
├── references/        # 可选：补充文档
└── assets/            # 可选：模板/图片/数据文件
```

## SKILL.md 格式

```markdown
---
name: code-review
description: "代码审查技能，帮助审查 Cangjie 代码质量"
allowed-tools: ["read_file", "grep", "bash"]
metadata:
  recommended-tools: ["read_file", "grep"]
---

## 代码审查流程

1. 先用 `read_file` 读取目标文件
2. 检查：命名规范、错误处理、性能问题
3. 输出审查报告，分严重/建议两级

## Cangjie 特定规则

- 使用 `Option<T>` 代替 null
- `match` 的 `case` 后不能接 `{}`
- 使用 `@Expect` 宏编写测试
```

### Frontmatter 字段

| 字段 | 必需 | 说明 |
|------|------|------|
| `name` | 是 | 唯一标识，全小写+连字符，匹配目录名 |
| `description` | 是 | 描述技能做什么及何时使用 |
| `license` | 否 | 许可证 |
| `compatibility` | 否 | 环境要求 |
| `allowed-tools` | 否 | 预授权工具列表（实验性） |
| `metadata` | 否 | 扩展字段 |

## 在 Agent 中使用

```toml
[[agent]]
name = "code-assistant"
model = "gpt-4o"
skills = ["code-review", "debugging"]
```

技能指令在运行时拼入 system prompt：

```
你是一个高级软件工程师...

## 代码审查流程
1. 先用 read_file 读取目标文件
2. 检查：命名规范、错误处理、性能问题
...
```

## 校验

Atelier 在加载时校验 SKILL.md 格式：
- name 与目录名一致
- 必需的 frontmatter 字段完整
- 格式非法时给出警告，不阻塞启动
