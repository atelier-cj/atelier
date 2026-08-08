# 自定义 Provider 扩展实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 让 Atelier 支持用户自定义 Provider 类型：代码注册工厂 + TOML 按 type 创建 + ChatRequest 透传任意扩展参数。

**Architecture:** 三件套增量改造——`ChatRequest` 加 `extra` 字典（重载构造保持兼容）；`ProviderFactory` 接口 + `ProviderConfig` 通用配置 + `ProviderRegistry` 扩展（`registerFactory`/`create`/`default()`）；`TomlProvider` 加 `extra` 字段并转换到 `ProviderConfig`，CLI 改用 `ProviderRegistry.default()` + `create(cfg)`。

**Tech Stack:** Cangjie 1.1.0, `jsonvalue`, `std.collection`, `tomlcj`

**设计文档:** `docs/plans/2026-08-08-custom-provider-design.md`

**项目根目录:** `/home/ystyle/Projects/Cangjie/atelier`

---

## Task 1: ChatRequest 增加 extra 字段

**Files:**
- Modify: `src/provider/interface.cj`
- Test: `src/provider/openai_test.cj`（或新建 provider_test.cj）

**Step 1: 写失败测试**

在 `src/provider/openai_test.cj` 追加（纯单元测试，不联网）：

```cangjie
@Test
func chatRequest_extraField() {
    let extra = HashMap<String, JsonValue>()
    extra["reasoning_effort"] = JsonValue.String("high")
    let req = ChatRequest("m", ArrayList<Message>(), 0.7, 100, None, ArrayList(), extra)
    match (req.extra.get("reasoning_effort")) {
        case Some(JsonValue.String(s)) => @Expect(s, "high")
        case _ => @Fail("extra not carried")
    }
}

@Test
func chatRequest_withoutExtra_hasEmptyMap() {
    let req = ChatRequest("m", ArrayList<Message>(), 0.7, 100, None, ArrayList())
    @Expect(req.extra.size, 0)
}
```

注意：`openai_test.cj` 是 `ProviderIntegrationTest` 类（`@Test` 类 + `@TestCase`）。`chatRequest_extraField` 不联网，应放独立测试类或函数。建议新建 `src/provider/provider_test.cj` 放纯单元测试，避免与集成测试类混在一起（profile filter 会排除整个 ProviderIntegrationTest 类）。

**Step 2: 运行测试确认失败**

```bash
eval "$(cjvs env zsh)" && eval "$(cjvs stdx-env zsh)"
cjpm test -j 16 --no-progress --filter 'chatRequest_extraField'
```
Expected: 编译失败，`extra` 字段不存在。

**Step 3: 实现**

```cangjie
public struct ChatRequest {
    public let model: String
    public let messages: ArrayList<Message>
    public let temperature: Float64
    public let maxTokens: Int64
    public let reasoningEffort: Option<String>
    public let tools: ArrayList<OpenAITool>
    public let extra: HashMap<String, JsonValue>

    public init(model: String, messages: ArrayList<Message>,
        temperature: Float64, maxTokens: Int64,
        reasoningEffort: Option<String>,
        tools: ArrayList<OpenAITool>,
        extra: HashMap<String, JsonValue>) {
        this.model = model; this.messages = messages
        this.temperature = temperature; this.maxTokens = maxTokens
        this.reasoningEffort = reasoningEffort
        this.tools = tools; this.extra = extra
    }

    public init(model: String, messages: ArrayList<Message>,
        temperature: Float64, maxTokens: Int64,
        reasoningEffort: Option<String>,
        tools: ArrayList<OpenAITool>) {
        this.model = model; this.messages = messages
        this.temperature = temperature; this.maxTokens = maxTokens
        this.reasoningEffort = reasoningEffort
        this.tools = tools; this.extra = HashMap<String, JsonValue>()
    }
}
```

**Step 4: 运行测试确认通过**

```bash
cjpm test -j 16 --no-progress --filter 'chatRequest_extraField|chatRequest_withoutExtra'
```
Expected: PASS

**Step 5: 提交**

```bash
git add src/provider/interface.cj src/provider/provider_test.cj
git commit -m "feat(provider): ChatRequest 增加 extra 扩展字段（重载构造保持兼容）"
```

---

## Task 2: ProviderFactory + ProviderConfig 定义

**Files:**
- Create: `src/provider/factory.cj`
- Test: `src/provider/provider_test.cj`

**Step 1: 写失败测试**

```cangjie
@Test
func providerFactory_typeAndCreate() {
    class FakeProviderImpl <: Provider {
        public let name: String
        public init(name: String) { this.name = name }
        public func name(): String { this.name }
        public func chat(req: ChatRequest): ChatResponse {
            ChatResponse(AssistantMessage(ContentList.ofText("fake"), "", "", StopReason.EndTurn, TokenUsage(0, 0), 0))
        }
        public func chatStreaming(req: ChatRequest): EventStream<ChatDelta, AssistantMessage> {
            let s = EventStream<ChatDelta, AssistantMessage>()
            s.emit(ChatDelta("fake", "", Some(StopReason.EndTurn)))
            s.setResult(AssistantMessage(ContentList.ofText("fake"), "", "", StopReason.EndTurn, TokenUsage(0, 0), 0))
            s
        }
    }
    class FakeFactory <: ProviderFactory {
        public func type(): String { "fake" }
        public func create(cfg: ProviderConfig): Provider { FakeProviderImpl(cfg.name) }
    }

    let f = FakeFactory()
    @Expect(f.type(), "fake")
    let cfg = ProviderConfig("f", "http://x", "", ArrayList(), HashMap<String, JsonValue>())
    let p = f.create(cfg)
    @Expect(p.name(), "f")
}
```

**Step 2: 运行测试确认失败**

```bash
cjpm test -j 16 --no-progress --filter 'providerFactory_typeAndCreate'
```
Expected: 编译失败，`ProviderFactory` / `ProviderConfig` 未定义。

**Step 3: 实现 factory.cj**

```cangjie
package atelier.provider

import jsonvalue.*
import std.collection.*

public struct ProviderConfig {
    public let name: String
    public let baseURL: String
    public let apiKey: String
    public let headers: ArrayList<String>
    public let extra: HashMap<String, JsonValue>

    public init(name: String, baseURL: String, apiKey: String,
        headers: ArrayList<String>, extra: HashMap<String, JsonValue>) {
        this.name = name; this.baseURL = baseURL
        this.apiKey = apiKey; this.headers = headers
        this.extra = extra
    }

    public static func empty(name: String): ProviderConfig {
        ProviderConfig(name, "", "", ArrayList<String>(), HashMap<String, JsonValue>())
    }
}

public interface ProviderFactory {
    func type(): String
    func create(cfg: ProviderConfig): Provider
}
```

**Step 4: 运行测试确认通过**

```bash
cjpm test -j 16 --no-progress --filter 'providerFactory_typeAndCreate'
```
Expected: PASS

**Step 5: 提交**

```bash
git add src/provider/factory.cj src/provider/provider_test.cj
git commit -m "feat(provider): 定义 ProviderFactory 接口与 ProviderConfig 通用配置"
```

---

## Task 3: ProviderRegistry 扩展（registerFactory / create / default）

**Files:**
- Modify: `src/provider/registry.cj`
- Test: `src/provider/provider_test.cj`

**Step 1: 写失败测试**

```cangjie
@Test
func registry_factoryRegisterAndCreate() {
    // 用 Task 2 的 FakeFactory 模式
    let reg = ProviderRegistry()
    reg.registerFactory(FakeFactory())
    @Expect(reg.getFactory("fake").isSome(), true)
    let cfg = ProviderConfig.empty("f")
    let p = reg.create(cfg)
    @Expect(p.name(), "f")
}

@Test
func registry_defaultHasBuiltinFactories() {
    let reg = ProviderRegistry.default()
    @Expect(reg.getFactory("openai").isSome(), true)
    @Expect(reg.getFactory("anthropic").isSome(), true)
    @Expect(reg.getFactory("ollama").isSome(), true)
}

@Test
func registry_createUnknownType_throws() {
    let reg = ProviderRegistry()
    let cfg = ProviderConfig.empty("x")
    var caught = false
    try { reg.create(cfg) } catch (e: Exception) { caught = true }
    @Expect(caught, true)
}
```

**Step 2: 运行测试确认失败**

```bash
cjpm test -j 16 --no-progress --filter 'registry_factoryRegisterAndCreate'
```
Expected: 编译失败，`registerFactory` 不存在。

**Step 3: 实现 registry.cj 扩展**

```cangjie
public class ProviderRegistry {
    private let providers = HashMap<String, Provider>()
    private let factories = HashMap<String, ProviderFactory>()

    public init() {}

    public static func default(): ProviderRegistry {
        let reg = ProviderRegistry()
        reg.registerFactory(OpenAIFactory())
        reg.registerFactory(AnthropicFactory())
        reg.registerFactory(OllamaFactory())
        reg
    }

    public func register(name: String, provider: Provider) {
        this.providers[name] = provider
    }

    public func registerFactory(f: ProviderFactory) {
        this.factories[f.type()] = f
    }

    public func getFactory(type: String): Option<ProviderFactory> {
        this.factories.get(type)
    }

    public func create(cfg: ProviderConfig): Provider {
        match (this.factories.get(cfg.name)) {
            case Some(f) => f.create(cfg)
            case None =>
                match (this.factories.get("default")) {
                    case Some(f) => f.create(cfg)
                    case None => throw Exception("No provider factory for type: " + cfg.name)
                }
        }
    }

    public func get(name: String): Option<Provider> {
        this.providers.get(name)
    }

    public func list(): ArrayList<Provider> {
        let result = ArrayList<Provider>()
        for ((_, p) in this.providers) { result.add(p) }
        result
    }

    public func has(name: String): Bool {
        this.providers.contains(name)
    }
}
```

> **注意**：`create` 用 `cfg.name` 作为 type 查找键？这里需要设计澄清——`ProviderConfig.name` 是实例名（如 "deepseek"），但工厂按 **type**（如 "deepseek" 或 "openai"）查找。设计文档里 `create(cfg)` 应按 `cfg.type` 查。需要给 `ProviderConfig` 加 `type` 字段，或 create 接受独立 type 参数。**本计划采用：ProviderConfig 增加 `type: String` 字段**（见 Task 5 的 ProviderConfig 最终形态），create 按 `cfg.type` 查找工厂。

**Step 4: 运行测试确认通过**

```bash
cjpm test -j 16 --no-progress --filter 'registry_'
```
Expected: PASS

**Step 5: 提交**

```bash
git add src/provider/registry.cj src/provider/provider_test.cj src/provider/factory.cj
git commit -m "feat(provider): ProviderRegistry 支持工厂注册/create/default() 静态构造器"
```

---

## Task 4: 内置三个工厂

**Files:**
- Modify: `src/provider/factory.cj`
- Modify: `src/provider/openai.cj`（构造支持 headers + extra）
- Modify: `src/provider/anthropic.cj`（构造支持 headers + extra）
- Modify: `src/provider/ollama.cj`（构造支持 headers + extra）

**Step 1: 写失败测试**

```cangjie
@Test
func builtinFactory_openai_create() {
    let f = OpenAIFactory()
    @Expect(f.type(), "openai")
    let cfg = ProviderConfig("my-openai", "http://localhost:8089", "key", ArrayList(), HashMap<String, JsonValue>())
    let p = f.create(cfg)
    @Expect(p.name(), "my-openai")
}
```

**Step 2: 实现三个内置工厂**

在 factory.cj 追加：

```cangjie
public class OpenAIFactory <: ProviderFactory {
    public func type(): String { "openai" }
    public func create(cfg: ProviderConfig): Provider {
        OpenAIProvider(cfg.name, cfg.baseURL, cfg.apiKey, cfg.headers)
    }
}

public class AnthropicFactory <: ProviderFactory {
    public func type(): String { "anthropic" }
    public func create(cfg: ProviderConfig): Provider {
        AnthropicProvider(cfg.name, cfg.baseURL, cfg.apiKey, cfg.headers)
    }
}

public class OllamaFactory <: ProviderFactory {
    public func type(): String { "ollama" }
    public func create(cfg: ProviderConfig): Provider {
        OllamaProvider(cfg.name, cfg.baseURL, cfg.headers)
    }
}
```

**Step 3: 扩展三个 Provider 构造**

OpenAIProvider 增加 headers 参数（原构造保留）：

```cangjie
// openai.cj 中新增字段
private let headers: ArrayList<String>

// 原构造保留（headers 空）
public init(name: String, baseURL: String, apiKey: String) {
    this.init(name, baseURL, apiKey, ArrayList<String>())
}

// 新构造
public init(name: String, baseURL: String, apiKey: String, headers: ArrayList<String>) {
    this.provName = name
    this.baseURL = baseURL.trimEnd('/')
    this.apiKey = apiKey
    this.headers = headers
    // ... 其余原逻辑
}
```

AnthropicProvider 同样加 headers 字段；OllamaProvider 加 headers（无 apiKey）。

请求头应用：在 `chat`/`doStreamRequest` 里对每个 header 字符串解析 `"Name: value"` 格式并 `.header(name, value)`。

extra 读取：`OpenAIProvider.chat` 里从 `req.extra` 取 `reasoning_effort` 覆盖 `req.reasoningEffort`；`response_format` 并入请求体。具体见 Task 5 的请求体改造。

**Step 4: 运行测试确认通过**

```bash
cjpm test -j 16 --no-progress --filter 'builtinFactory_openai_create'
```
Expected: PASS

**Step 5: 提交**

```bash
git add src/provider/factory.cj src/provider/openai.cj src/provider/anthropic.cj src/provider/ollama.cj src/provider/provider_test.cj
git commit -m "feat(provider): 内置 OpenAI/Anthropic/Ollama 工厂 + Provider 构造支持自定义请求头"
```

---

## Task 5: ProviderConfig 加 type + extra 透传进请求体

**Files:**
- Modify: `src/provider/factory.cj`（ProviderConfig 加 type）
- Modify: `src/provider/openai.cj`（请求体并入 extra）
- Modify: `src/provider/anthropic.cj`
- Modify: `src/provider/ollama.cj`
- Test: `src/provider/provider_test.cj`

**Step 1: ProviderConfig 增加 type 字段**

```cangjie
public struct ProviderConfig {
    public let type: String        // 工厂类型名（新增）
    public let name: String        // 实例名
    public let baseURL: String
    public let apiKey: String
    public let headers: ArrayList<String>
    public let extra: HashMap<String, JsonValue>

    public init(type: String, name: String, baseURL: String, apiKey: String,
        headers: ArrayList<String>, extra: HashMap<String, JsonValue>) { ... }

    public static func empty(name: String): ProviderConfig {
        ProviderConfig("", name, "", "", ArrayList<String>(), HashMap<String, JsonValue>())
    }
}
```

Registry.create 改为按 `cfg.type` 查工厂。

**Step 2: OpenAI 请求体并入 extra**

在 `buildRequest` 或 `chat` 里：

```cangjie
// openai.cj chat 内
let extraEffort = match (req.extra.get("reasoning_effort")) {
    case Some(JsonValue.String(s)) => Some(s)
    case _ => req.reasoningEffort
}
// 构造 OpenAIRequest 时用 extraEffort
```

若 extra 含 `response_format`（JsonValue），并入请求体 body（`buildRequest` 返回 OpenAIRequest 后转 JsonValue 再塞字段，或 OpenAIRequest 增加 responseFormat 字段——以 OpenAIRequest 现有结构为准）。

**Step 3: Anthropic/Ollama 同理**

- Anthropic：`extra["thinking"]`、`extra["max_tokens"]` 覆盖等
- Ollama：`extra["format"]`、`extra["keep_alive"]` 等

**Step 4: 测试**

```cangjie
@Test
func openaiRequest_extraReasoningEffort() {
    // 构造 ChatRequest 带 extra reasoning_effort="high"
    // 验证 buildRequest 产出的请求体含该字段
}
```

**Step 5: 提交**

```bash
git add src/provider/factory.cj src/provider/openai.cj src/provider/anthropic.cj src/provider/ollama.cj src/provider/provider_test.cj
git commit -m "feat(provider): ProviderConfig 增加 type，extra 透传进三种内置 Provider 请求体"
```

---

## Task 6: TomlProvider 加 extra + 转换到 ProviderConfig

**Files:**
- Modify: `src/server/config.cj`
- Test: 无（配置解析在 CLI 集成验证）

**Step 1: TomlProvider 加 extra 字段**

```cangjie
public class TomlProvider <: Serializable<TomlProvider> {
    public var name: String = ""
    public var providerType: String = "openai"
    public var baseURL: String = ""
    public var apiKey: String = ""
    public var headers: ArrayList<String> = ArrayList()
    public var extra: HashMap<String, JsonValue> = HashMap()   // 新增
    public init() {}
    // serialize/deserialize 加 extra（TOML table → HashMap<String, JsonValue>）
}
```

extra 的 TOML 解析：`extra = { reasoning_effort = "high" }` → 从 `DataModelStruct` 转 `HashMap<String, JsonValue>`。

**Step 2: 转换函数**

```cangjie
// config.cj 或 cli/main.cj
func toProviderConfig(tp: TomlProvider): ProviderConfig {
    ProviderConfig(tp.providerType, tp.name, tp.baseURL, tp.apiKey,
        tp.headers, tp.extra)
}
```

**Step 3: 提交**

```bash
git add src/server/config.cj
git commit -m "feat(config): TomlProvider 增加 extra 字段与 ProviderConfig 转换"
```

---

## Task 7: CLI 改用 ProviderRegistry.default() + create(cfg)

**Files:**
- Modify: `src/cli/main.cj`

**Step 1: 改造 provider 创建逻辑**

```cangjie
// 原：
let providerReg = ProviderRegistry()

// 改：
let providerReg = ProviderRegistry.default()

// 原 match 分支（cli/main.cj:63-70）：
for (p in config.provider) {
    let prov: Provider = match (p.providerType) {
        case "ollama" => OllamaProvider(p.name, p.baseURL)
        case "anthropic" => AnthropicProvider(p.name, p.baseURL, p.apiKey)
        case _ => OpenAIProvider(p.name, p.baseURL, p.apiKey)
    }
    providerReg.register(p.name, prov)
}

// 改为：
for (p in config.provider) {
    let cfg = toProviderConfig(p)
    let prov = providerReg.create(cfg)
    providerReg.register(p.name, prov)
}
```

**Step 2: 验证编译 + 全量测试**

```bash
cjpm build -j 16 && cjpm test -j 16 --no-progress
```
Expected: 全部通过。

**Step 3: 手动验证自定义 type**

临时在 `~/.atelier.toml` 加一个不存在的 type（如 `type = "custom-xxx"`），确认报错提示（"No provider factory for type"）而非静默 fallback 到 OpenAI。

**Step 4: 提交**

```bash
git add src/cli/main.cj
git commit -m "feat(cli): 改用 ProviderRegistry.default() 并按工厂 create 创建 Provider"
```

---

## Task 8: 文档更新

**Files:**
- Modify: `docs/providers.md`（或 `docs/configuration.md`）

**Step 1: providers.md 加"自定义 Provider"章节**

- 库模式：实现 Provider + ProviderFactory，`reg.registerFactory()`
- 配置模式：TOML `type` + 工厂注册
- ChatRequest.extra 用法（reasoning_effort 等）
- headers 自定义请求头

**Step 2: configuration.md 更新 provider 配置示例**

```toml
[[provider]]
name = "deepseek"
type = "deepseek"
baseURL = "https://api.deepseek.com"
apiKey = "${DEEPSEEK_API_KEY}"
headers = ["x-custom: value"]
extra = { reasoning_effort = "high" }
```

**Step 3: 提交**

```bash
git add docs/providers.md docs/configuration.md
git commit -m "docs(provider): 自定义 Provider 工厂、extra 透传、headers 用法"
```

---

## Task 9: 全量验证

**Step 1: 编译 + 全量测试**

```bash
eval "$(cjvs env zsh)" && eval "$(cjvs stdx-env zsh)"
cjpm build -j 16
cjpm test -j 16 --no-progress
```
Expected: 全部通过（含 6 个集成测试 SKIPPED）。

**Step 2: 检查旧签名残留**

```bash
grep -rn 'match (p.providerType)' src/  # 不应再有
grep -rn 'ProviderConfig(' src/ | grep -v 'cfg'  # 确认新构造使用一致
```

**Step 3: 最终提交**

```bash
git add -A && git commit -m "chore: 自定义 Provider 扩展完成" 2>/dev/null || echo "无待提交改动"
```

---

## 待定事项

| 事项 | 说明 |
|------|------|
| OpenAIRequest 结构 | Task 5 需确认现有 `OpenAIRequest` 字段（在 `openai_types.cj`），response_format 是否已有字段 |
| Anthropic/Ollama extra 具体 key | 以实际 API 为准，Task 5 时确认 |
| handler.cj resolveProvider | 当前硬编码 OpenAIProvider("default", "http://localhost:8089", "")，Task 7 可顺带改为走工厂（可选） |
