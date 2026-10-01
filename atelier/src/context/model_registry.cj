package atelier.context

import std.collection.*

/**
 * 模型 → 上下文窗口（token）查表。
 *
 * 窗口是 **`(provider, model)` 这一对路由的事实**，不是 agent 的属性：同名模型走官方端点和
 * 走一个截断过的代理，窗口可以不同；agent 只负责选这一对。所以表分两层：
 *
 * 1. **端点层**（[windowFor]）：`provider + model` 精确声明 —— 配置文件 `[[provider.model]]`
 * 2. **模型名层**（[get]）：内置查找表 + 按模型名的全局声明
 *
 * 未命中任一层时用 [defaultContextWindow] 兜底，调用方应据此**留痕**（见 [has]）：
 * 静默按偏小的值提前压缩，表现为"模型聊着聊着忘了前面"，而下游看不到任何线索。
 */
public class ModelContextRegistry {
    // 模型名层：内置表 + 按名字的声明
    private let knownModels: HashMap<String, Int64>
    // 端点层：provider → (model → window)
    private let providerModels: HashMap<String, HashMap<String, Int64>>

    /** 未命中时的兜底窗口（token）。默认 8192，可在此或装配层覆盖 */
    public let defaultContextWindow: Int64

    public init(defaultWindow!: Int64 = 8192) {
        this.defaultContextWindow = defaultWindow
        this.providerModels = HashMap<String, HashMap<String, Int64>>()
        this.knownModels = HashMap<String, Int64>()
        this.knownModels["gpt-4o"] = 128000
        this.knownModels["gpt-4o-mini"] = 128000
        this.knownModels["gpt-4-turbo"] = 128000
        this.knownModels["gpt-4"] = 8192
        this.knownModels["gpt-4-32k"] = 32768
        this.knownModels["gpt-3.5-turbo"] = 16384
        this.knownModels["gpt-3.5-turbo-16k"] = 16384
        this.knownModels["deepseek-chat"] = 65536
        this.knownModels["deepseek-coder"] = 16384
        this.knownModels["deepseek-reasoner"] = 65536
        this.knownModels["claude-sonnet-4"] = 200000
        this.knownModels["claude-3.5-sonnet"] = 200000
        this.knownModels["claude-3-opus"] = 200000
        this.knownModels["claude-3-sonnet"] = 200000
        this.knownModels["claude-3-haiku"] = 200000
        this.knownModels["gemini-1.5-pro"] = 1048576
        this.knownModels["gemini-1.5-flash"] = 1048576
        this.knownModels["gemini-2.0-flash"] = 1048576
        this.knownModels["qwen-turbo"] = 131072
        this.knownModels["qwen-plus"] = 131072
        this.knownModels["qwen-max"] = 131072
    }

    private init(known: HashMap<String, Int64>, providerModels: HashMap<String, HashMap<String, Int64>>,
        defaultWindow: Int64) {
        this.knownModels = known
        this.providerModels = providerModels
        this.defaultContextWindow = defaultWindow
    }

    /** 模型名层：内置表命中或按名字声明过，返回其窗口；否则兜底值 */
    public func get(model: String): Int64 {
        match (this.knownModels.get(model)) {
            case Some(v) => v
            case None => this.defaultContextWindow
        }
    }

    /** 模型名层是否**显式**知道这个模型（false = [get] 走的是兜底值） */
    public func has(model: String): Bool {
        this.knownModels.contains(model)
    }

    // 注册自定义模型及其上下文窗口（覆盖内置同名项）
    public func register(model: String, contextWindow: Int64): Unit {
        this.knownModels[model] = contextWindow
    }

    /** 端点层：`provider` 上的 `model` 是否声明过窗口 */
    public func hasFor(provider: String, model: String): Bool {
        match (this.providerModels.get(provider)) {
            case Some(m) => m.contains(model)
            case None => false
        }
    }

    /** 端点层窗口；未声明返回 None（调用方自行回退到模型名层 / 兜底） */
    public func windowFor(provider: String, model: String): Option<Int64> {
        match (this.providerModels.get(provider)) {
            case Some(m) => m.get(model)
            case None => None
        }
    }

    /** 声明「`provider` 上的 `model` 窗口是 N」（端点层，覆盖同名模型的全局声明） */
    public func registerFor(provider: String, model: String, contextWindow: Int64): Unit {
        match (this.providerModels.get(provider)) {
            case Some(m) => m[model] = contextWindow
            case None =>
                let m = HashMap<String, Int64>()
                m[model] = contextWindow
                this.providerModels[provider] = m
        }
    }

    /** 派生一份「多了一条端点层声明」的表（原表不动） */
    public func mergedFor(provider: String, model: String, contextWindow: Int64): ModelContextRegistry {
        let next = this.copyProviders()
        match (next.get(provider)) {
            case Some(m) => m[model] = contextWindow
            case None =>
                let m = HashMap<String, Int64>()
                m[model] = contextWindow
                next[provider] = m
        }
        ModelContextRegistry(this.copyKnown(), next, this.defaultContextWindow)
    }

    /**
     * 派生一份「在**模型名层**登记 model → contextWindow」的表。
     *
     * 用于按模型名全局声明（不分端点）；单个端点的事实请用 [mergedFor]。
     */
    public func merged(model: String, contextWindow: Int64): ModelContextRegistry {
        let copy = this.copyKnown()
        copy[model] = contextWindow
        ModelContextRegistry(copy, this.copyProviders(), this.defaultContextWindow)
    }

    /** 派生一份「换一个兜底窗口」的表（条目照旧） */
    public func withDefaultWindow(defaultWindow: Int64): ModelContextRegistry {
        ModelContextRegistry(this.copyKnown(), this.copyProviders(), defaultWindow)
    }

    // 全部已知模型名（去重无序，供枚举模型候选等场景）
    public func list(): ArrayList<String> {
        let names = HashSet<String>()
        for (k in this.knownModels.keys()) { names.add(k) }
        for (m in this.providerModels.values()) {
            for (k in m.keys()) { names.add(k) }
        }
        ArrayList<String>(names)
    }

    // 内置默认模型的上下文窗口（注册表未命中时使用）
    public func windowOf(model: String): Int64 {
        this.get(model)
    }

    private func copyKnown(): HashMap<String, Int64> {
        let copy = HashMap<String, Int64>()
        for (k in this.knownModels.keys()) { copy[k] = this.knownModels[k] }
        copy
    }

    private func copyProviders(): HashMap<String, HashMap<String, Int64>> {
        let copy = HashMap<String, HashMap<String, Int64>>()
        for (p in this.providerModels.keys()) {
            let inner = HashMap<String, Int64>()
            match (this.providerModels.get(p)) {
                case Some(m) =>
                    for (k in m.keys()) { inner[k] = m[k] }
                case None => ()
            }
            copy[p] = inner
        }
        copy
    }
}
