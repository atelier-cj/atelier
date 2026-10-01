package atelier.context

import std.collection.*

/**
 * 模型 → 上下文窗口（token）查表。
 *
 * 表里只有「内置已知模型」；**真实窗口是模型的属性，不是库的属性** —— 新模型、代理服务
 * 截断后的窗口、超长上下文变体都会与内置表不符。所以：
 *
 * - 宿主/配置应显式声明（`HarnessSpec.withModelContext` / `[[model]]` / `AgentConfig.contextWindow`）；
 * - 未命中时用 [defaultContextWindow] 兜底，调用方应据此**留痕**（见 [has]），
 *   否则会静默按一个偏小的窗口提前压缩上下文。
 */
public class ModelContextRegistry {
    private let knownModels: HashMap<String, Int64>

    /** 未命中时的兜底窗口（token）。默认 8192，可在此或装配层覆盖 */
    public let defaultContextWindow: Int64

    public init(defaultWindow!: Int64 = 8192) {
        this.defaultContextWindow = defaultWindow
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

    private init(known: HashMap<String, Int64>, defaultWindow: Int64) {
        this.knownModels = known
        this.defaultContextWindow = defaultWindow
    }

    public func get(model: String): Int64 {
        match (this.knownModels.get(model)) {
            case Some(v) => v
            case None => this.defaultContextWindow
        }
    }

    /** 表里是否**显式**知道这个模型（false = [get] 走的是兜底值） */
    public func has(model: String): Bool {
        this.knownModels.contains(model)
    }

    // 注册自定义模型及其上下文窗口（覆盖内置同名项）
    public func register(model: String, contextWindow: Int64): Unit {
        this.knownModels[model] = contextWindow
    }

    /**
     * 派生一份「在副本上登记 model → contextWindow」的表。
     *
     * 用于按 agent 覆盖窗口：原表（可能是共享的装配组件）不被改写。
     */
    public func merged(model: String, contextWindow: Int64): ModelContextRegistry {
        let copy = HashMap<String, Int64>()
        for (k in this.knownModels.keys()) {
            copy[k] = this.knownModels[k]
        }
        copy[model] = contextWindow
        ModelContextRegistry(copy, this.defaultContextWindow)
    }

    /** 派生一份「换一个兜底窗口」的表（条目照旧） */
    public func withDefaultWindow(defaultWindow: Int64): ModelContextRegistry {
        let copy = HashMap<String, Int64>()
        for (k in this.knownModels.keys()) {
            copy[k] = this.knownModels[k]
        }
        ModelContextRegistry(copy, defaultWindow)
    }

    // 全部已知模型名（去重无序，供枚举模型候选等场景）
    public func list(): ArrayList<String> {
        ArrayList<String>(this.knownModels.keys())
    }

    // 内置默认模型的上下文窗口（注册表未命中时使用）
    public func windowOf(model: String): Int64 {
        this.get(model)
    }
}
