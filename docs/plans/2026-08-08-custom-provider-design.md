# 自定义 Provider 扩展设计

> **日期:** 2026-08-08
> **状态:** 已确认，待实现

## 背景与目标

Atelier 当前内置 3 种 Provider（OpenAI 兼容 / Anthropic / Ollama），但存在三个扩展痛点：

1. **配置层只认 3 个 type**：`~/.atelier.toml` 里 `type = "openai" | "anthropic" | "ollama"`，其他 type 全部 fallback 到 OpenAI（`cli/main.cj:64-68`），无法配置驱动自定义格式
2. **`ChatRequest` 固定结构**：只有 model/messages/temperature/maxTokens/reasoningEffort/tools，没有额外参数透传通道——DeepSeek V4 的 `reasoning_content`、thinking 级别、response_format 等新参数无法传入
3. **`TomlProvider.headers` 是死配置**：定义了但从未传给 Provider 构造

**目标**：

- 代码层：库用户可自定义任意格式的 Provider 类（现状已支持）
- 配置层：TOML 按 `type` 字符串创建自定义 Provider（需工厂机制）
- 请求层：`ChatRequest` 可携带任意扩展参数（extra 字典）
- 内置类型统一走工厂，用户可覆盖

## 方案总览（方案 A：最小增量）

三件套，改动集中在 provider 层：

1. `ChatRequest` 加 `extra` 字典
2. `ProviderFactory` 接口 + Registry 扩展 + `default()` 静态构造器
3. `TomlProvider` 加 `extra` + `ProviderConfig` 解耦

## 一、`ChatRequest.extra` 扩展字段

```cangjie
public struct ChatRequest {
    public let model: String
    public let messages: ArrayList<Message>
    public let temperature: Float64
    public let maxTokens: Int64
    public let reasoningEffort: Option<String>
    public let tools: ArrayList<OpenAITool>
    public let extra: HashMap<String, JsonValue>   // 新增

    // 原构造签名保留（extra 为空），不破坏现有调用
    public init(model, messages, temperature, maxTokens, reasoningEffort, tools)

    // 新增重载：带 extra
    public init(model, messages, temperature, maxTokens, reasoningEffort, tools, extra)
}
```

**读取方**：
- `OpenAIProvider`：`extra["reasoning_effort"]`、`extra["response_format"]` 等 → 并入请求体
- `AnthropicProvider`：`extra["thinking"]` 等
- 自定义 Provider：完全自取

**Hook 联动**：`beforeTurn` hook 可通过改写 `ChatRequest.extra` 实现动态参数注入（模型路由增强）。

## 二、ProviderFactory 工厂机制

### 工厂接口

```cangjie
public interface ProviderFactory {
    func type(): String                              // "openai" / "deepseek" 等
    func create(cfg: ProviderConfig): Provider       // 按配置创建实例
}
```

### ProviderConfig（从 TOML 配置解耦）

```cangjie
public struct ProviderConfig {
    public let name: String
    public let baseURL: String
    public let apiKey: String
    public let headers: ArrayList<String>          // 自定义请求头（修复死配置）
    public let extra: HashMap<String, JsonValue>   // 配置层透传参数
}
```

### ProviderRegistry 扩展

```cangjie
public class ProviderRegistry {
    // 已有：register(name, provider) / get / list / has
    private let factories = HashMap<String, ProviderFactory>()

    public func registerFactory(f: ProviderFactory): Unit
    public func getFactory(type: String): Option<ProviderFactory>
    public func create(cfg: ProviderConfig): Provider   // 按 cfg.name 查工厂创建

    // 静态构造器：带内置 openai/anthropic/ollama 工厂
    public static func default(): ProviderRegistry
}
```

### 内置工厂

- `OpenAIFactory`（type="openai"）
- `AnthropicFactory`（type="anthropic"）
- `OllamaFactory`（type="ollama"）

构造变化：Anthropic/Ollama 的 `init` 需支持 headers（原构造保留，新增重载或工厂内用新构造）。

### 注册位置

- **`ProviderRegistry.default()`**：返回带内置工厂的实例
- **`ProviderRegistry()`**：空构造，库集成作者完全自控
- **`cli/main.cj`**：改用 `ProviderRegistry.default()`（行为与现在一致）

### 用户自定义示例

```cangjie
class DeepSeekFactory <: ProviderFactory {
    public func type(): String { "deepseek" }
    public func create(cfg: ProviderConfig): Provider { DeepSeekProvider(cfg) }
}
providerReg.registerFactory(DeepSeekFactory())
```

## 三、配置层与数据流

### TomlProvider 扩展

```toml
[[provider]]
name = "deepseek"
type = "deepseek"          # 走用户注册的 DeepSeekFactory
baseURL = "https://api.deepseek.com"
apiKey = "${DEEPSEEK_API_KEY}"
headers = ["x-custom: value"]          # 自定义请求头
extra = { reasoning_effort = "high" }  # 透传扩展参数
```

### 数据流

```
TOML:  extra = { reasoning_effort = "high", top_p = 0.9 }
   │  tomlcj（DataModel 原生，类型保真：String + Float）
   ▼
TomlProvider.extra: DataModel           ← 零转换（serialize/deserialize 原样存取）
   │  toProviderConfig 边界（三行官方 API 转换）
   ▼
ProviderConfig.extra: HashMap<String, JsonValue>   ← 类型保真
   │  providerReg.create(cfg) → 按 cfg.type 查工厂
   ▼
DeepSeekProvider（工厂 create 构造）
   │  runtime.chat(ChatRequest(..., extra))
   ▼
JSON 请求体: {"reasoning_effort": "high", "top_p": 0.9}   ← 数字保真
```

**extra 类型分层**（配置与请求各自用本体系，互不侵入）：

| 层 | 类型 | 序列化 | 转换 |
|---|---|---|---|
| 配置 DTO（TomlProvider.extra） | `DataModel` | tomlcj 原生（`Field("extra", dm)` 原样存取） | 无 |
| 边界（toProviderConfig） | — | — | 三行官方 API：`dm.toJson()`（stdx）→ `toJsonString()` → `JsonValue.parse()`（jsonvalue） |
| Provider/请求（ProviderConfig.extra / ChatRequest.extra） | `HashMap<String, JsonValue>` | jsonvalue 原生 | 无 |

TOML 与 JSON 是两个独立体系，各用各的 any 类型（`DataModel` / `JsonValue`），中间转换只发生在边界一次，利用 stdx 官方 `DataModel.toJson()` 扩展 + `toJsonString()` + jsonvalue `JsonValue.parse()`，零手写遍历。

### 关键改造点

| 文件 | 改动 |
|------|------|
| `src/provider/interface.cj` | ChatRequest 加 extra（重载构造） |
| `src/provider/registry.cj` | ProviderFactory 支持 + create + default() |
| `src/provider/factory.cj`（新） | ProviderFactory 接口 + ProviderConfig + 3 个内置工厂 |
| `src/provider/openai.cj` | 构造支持 headers + extra 读 key 并入请求体 |
| `src/provider/anthropic.cj` | 构造支持 headers + extra 读 key |
| `src/provider/ollama.cj` | 构造支持 headers + extra 读 key |
| `src/server/config.cj` | TomlProvider.extra 用 `DataModel`（原生）；toProviderConfig 三行官方 API 转 `HashMap<String, JsonValue>` |
| `src/cli/main.cj` | 用 ProviderRegistry.default() + create(cfg) 替换 match 分支 |
| `src/server/handler.cj` | resolveProvider 用 create(cfg)（若涉及） |

### 兼容性

- 现有 TOML（openai/anthropic/ollama）完全不变
- 现有 `ChatRequest(...)` 调用不变（extra 默认空）
- 现有 `ProviderRegistry()` 空构造行为不变；CLI 改为 default() 行为等价

## 测试计划

1. **ChatRequest extra**：构造带/不带 extra；字段读写
2. **ProviderFactory**：注册/查询/按 type create；未注册 type 抛异常
3. **default() 构造器**：默认带 3 个内置工厂；空构造无工厂
4. **自定义工厂端到端**：注册 FakeFactory（type="fake"），TOML 配置 type="fake" → create 出 FakeProvider
5. **extra 透传端到端**：FakeProvider 收到 ChatRequest.extra 里的 key
6. **headers 修复**：FakeProvider 收到自定义请求头（验证不再是死配置）
7. **回归**：现有 OpenAI/Anthropic/Ollama 集成测试不破坏

## 不在范围内

- 不引入反射（Cangjie 无反射，工厂显式注册）
- 不改 HTTP API 层的 provider 动态创建端点（如需要后续单独设计）
- 不做 Provider 热更新/配置热加载
