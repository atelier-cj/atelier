package atelier.context

import std.collection.*
import llm_api.provider.ModelInfo

/**
 * 模型事实的**声明表**：宿主用配置说清"这个端点上的这个模型，窗口多大、完成预算多少"。
 *
 * 分两层：
 * 1. **端点层**（[infoFor]）：`provider + model` 精确声明 —— 配置文件 `[[provider.model]]`
 * 2. **模型名层**（[info]）：不分端点的全局声明
 *
 * 两层都只是**声明**：provider 自报（`Provider.modelInfo`）与内置目录（llm_api 的
 * `ModelCatalog`）在更下层兜底，由运行时按「声明 > 自报 > 兜底」串起来
 * （见 `HarnessSpec.resolveModelInfo`）。
 *
 * 为什么按 `(provider, model)` 而不是只按模型名：窗口是端点的事实。同一个 `deepseek-chat`，
 * 官方端点是 64k，经由一个截断过的代理可能就是 32k —— 只按模型名声明，等于让两个端点
 * 共用一个数，必有一个是错的。agent 只负责**选**这一对，不持有这个事实。
 */
public class ModelContextRegistry {
    // 模型名层：按名字的全局声明
    private let byName: HashMap<String, ModelInfo>
    // 端点层：provider → (model → info)
    private let byProvider: HashMap<String, HashMap<String, ModelInfo>>

    /** 全链路都没声明时的兜底窗口（token）。默认 8192，可在此或装配层覆盖 */
    public let defaultContextWindow: Int64

    /** 全链路都没声明时的兜底完成预算（token） */
    public let defaultMaxTokens: Int64

    public init(defaultWindow!: Int64 = 8192, defaultMaxTokens!: Int64 = 4096) {
        this.defaultContextWindow = defaultWindow
        this.defaultMaxTokens = defaultMaxTokens
        this.byName = HashMap<String, ModelInfo>()
        this.byProvider = HashMap<String, HashMap<String, ModelInfo>>()
    }

    private init(byName: HashMap<String, ModelInfo>, byProvider: HashMap<String, HashMap<String, ModelInfo>>,
        defaultWindow: Int64, defaultMaxTokens: Int64) {
        this.byName = byName
        this.byProvider = byProvider
        this.defaultContextWindow = defaultWindow
        this.defaultMaxTokens = defaultMaxTokens
    }

    // ---------- 模型名层 ----------

    /** 按模型名声明过就给它的窗口，否则兜底值 */
    public func get(model: String): Int64 {
        match (this.byName.get(model)) {
            case Some(info) => if (info.contextWindow > 0) { info.contextWindow } else { this.defaultContextWindow }
            case None => this.defaultContextWindow
        }
    }

    // 兼容旧名（默认模型的上下文窗口）
    public func windowOf(model: String): Int64 {
        this.get(model)
    }

    /** 模型名层是否**显式**声明过（false = 取的是兜底值） */
    public func has(model: String): Bool {
        this.byName.contains(model)
    }

    /** 模型名层的声明；未声明返回 None */
    public func info(model: String): Option<ModelInfo> {
        this.byName.get(model)
    }

    /** 按模型名声明事实（覆盖同名旧声明） */
    public func register(model: String, info: ModelInfo): Unit {
        this.byName[model] = info
    }

    /** 按模型名声明窗口（完成预算留 0 = 另说） */
    public func register(model: String, contextWindow: Int64): Unit {
        this.register(model, ModelInfo(contextWindow, 0))
    }

    // ---------- 端点层 ----------

    /** 端点层是否声明过 */
    public func hasFor(provider: String, model: String): Bool {
        match (this.byProvider.get(provider)) {
            case Some(m) => m.contains(model)
            case None => false
        }
    }

    /** 端点层的声明；未声明返回 None（调用方自行回退到模型名层 / provider 自报 / 兜底） */
    public func infoFor(provider: String, model: String): Option<ModelInfo> {
        match (this.byProvider.get(provider)) {
            case Some(m) => m.get(model)
            case None => None
        }
    }

    /** 端点层声明的窗口（未声明、或只声明了完成预算时返回 None） */
    public func windowFor(provider: String, model: String): Option<Int64> {
        match (this.infoFor(provider, model)) {
            case Some(info) => if (info.contextWindow > 0) { Some(info.contextWindow) } else { None }
            case None => None
        }
    }

    /** 声明「`provider` 上的 `model` 事实如此」 */
    public func registerFor(provider: String, model: String, info: ModelInfo): Unit {
        match (this.byProvider.get(provider)) {
            case Some(m) => m[model] = info
            case None =>
                let m = HashMap<String, ModelInfo>()
                m[model] = info
                this.byProvider[provider] = m
        }
    }

    // ---------- 派生（副本语义，不动原表） ----------

    /** 派生一份「多了一条端点层声明」的表 */
    public func mergedFor(provider: String, model: String, info: ModelInfo): ModelContextRegistry {
        let next = this.copyProviders()
        match (next.get(provider)) {
            case Some(m) => m[model] = info
            case None =>
                let m = HashMap<String, ModelInfo>()
                m[model] = info
                next[provider] = m
        }
        ModelContextRegistry(this.copyByName(), next, this.defaultContextWindow, this.defaultMaxTokens)
    }

    /** 派生一份「在模型名层登记」的表（不分端点的全局声明） */
    public func merged(model: String, info: ModelInfo): ModelContextRegistry {
        let copy = this.copyByName()
        copy[model] = info
        ModelContextRegistry(copy, this.copyProviders(), this.defaultContextWindow, this.defaultMaxTokens)
    }

    /** 派生一份「换兜底值」的表 */
    public func withDefaults(defaultWindow: Int64, defaultMaxTokens: Int64): ModelContextRegistry {
        ModelContextRegistry(this.copyByName(), this.copyProviders(), defaultWindow, defaultMaxTokens)
    }

    /** 显式声明过的模型名（不含 provider 自报 / 内置目录 —— 那些不在本表里） */
    public func list(): ArrayList<String> {
        ArrayList<String>(this.byName.keys())
    }

    private func copyByName(): HashMap<String, ModelInfo> {
        let copy = HashMap<String, ModelInfo>()
        for (k in this.byName.keys()) { copy[k] = this.byName[k] }
        copy
    }

    private func copyProviders(): HashMap<String, HashMap<String, ModelInfo>> {
        let copy = HashMap<String, HashMap<String, ModelInfo>>()
        for (p in this.byProvider.keys()) {
            let inner = HashMap<String, ModelInfo>()
            match (this.byProvider.get(p)) {
                case Some(m) =>
                    for (k in m.keys()) { inner[k] = m[k] }
                case None => ()
            }
            copy[p] = inner
        }
        copy
    }
}
