package atelier.acp

import std.collection.*
import acp.types.*
import jsonvalue.*

// ACP Session Config Options 的选项 id（wire 上稳定）
public const AcpOptionModel: String = "model"
public const AcpOptionCompaction: String = "compaction"

// 会话级配置覆盖状态 + config options 列表组装。
// 语义对齐 ACP v1 Session Config Options：
// - session/new 时下发完整列表（含当前值）
// - set_config_option 校验后写入，响应回完整最新列表
// - 覆盖只作用于本 ACP 会话（per-session 实例），进程内有效
public class AcpConfigOptions {
    private let candidates: ArrayList<String>   // 可选模型（有序）
    private let defaultModel: String
    private let defaultCompaction: Bool
    private var model: String
    private var compaction: Bool

    public init(candidates: ArrayList<String>, defaultModel: String, defaultCompaction: Bool) {
        // 去重且保证 defaultModel 一定在候选集内（select 的 currentValue 必须可选项）
        let seen = HashSet<String>()
        this.candidates = ArrayList<String>()
        for (m in candidates) {
            if (!seen.contains(m)) {
                seen.add(m)
                this.candidates.add(m)
            }
        }
        if (!seen.contains(defaultModel)) {
            this.candidates.add(defaultModel)
        }
        this.defaultModel = defaultModel
        this.defaultCompaction = defaultCompaction
        this.model = defaultModel
        this.compaction = defaultCompaction
    }

    // 完整 config options 列表（当前值状态）
    public func optionList(): ArrayList<SessionConfigOption> {
        let out = ArrayList<SessionConfigOption>()

        let modelOpt = SessionConfigOption(AcpOptionModel, "模型")
        modelOpt.category = Some("model_config")
        modelOpt.`type` = "select"
        modelOpt.currentValue = Some(this.model)
        let values = ArrayList<SessionConfigSelectOption>()
        for (m in this.candidates) {
            let v = SessionConfigSelectOption()
            v.value = m
            v.name = m
            values.add(v)
        }
        modelOpt.options = Some(values)
        out.add(modelOpt)

        let compOpt = SessionConfigOption(AcpOptionCompaction, "上下文压缩")
        compOpt.`type` = "boolean"
        compOpt.currentBool = Some(this.compaction)
        out.add(compOpt)

        out
    }

    // 应用 set_config_option：未知 id / 非法值返回 false（调用方回 -32602）
    public func setOption(id: String, value: JsonValue): Bool {
        if (id == AcpOptionModel) {
            match (value) {
                case JsonValue.String(m) =>
                    for (c in this.candidates) {
                        if (c == m) {
                            this.model = m
                            return true
                        }
                    }
                    false
                case _ => false
            }
        } else if (id == AcpOptionCompaction) {
            match (value) {
                case JsonValue.Boolean(b) =>
                    this.compaction = b
                    true
                case _ => false
            }
        } else {
            false
        }
    }

    // 当前生效值（PromptRunner 回合前读取）
    public func effectiveModel(): String { this.model }
    public func effectiveCompaction(): Bool { this.compaction }

    // 会话结束（close/resume 重建）时恢复默认
    public func reset(): Unit {
        this.model = this.defaultModel
        this.compaction = this.defaultCompaction
    }
}
