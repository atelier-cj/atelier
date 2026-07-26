package atelier.context

import std.collection.*

public class ModelContextRegistry {
    private let knownModels = HashMap<String, Int64>()

    public let defaultContextWindow: Int64 = 8192

    public init() {
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

    public func get(model: String): Int64 {
        match (this.knownModels.get(model)) {
            case Some(v) => v
            case None => this.defaultContextWindow
        }
    }
}
