package server

import atelier.agent.*
import atelier.context.{CompactionConfig, ToolResultPruneConfig}
import atelier.provider.*
import atelier.tool.McpServerConfig
import atelier.ptc.ToolPresentationMode
import tomlcj.*
import stdx.serialization.serialization.*
import std.collection.*
import std.fs.*
import std.env.*
import jsonvalue.*

public struct StoreType {
    public let name: String
    public init(name: String) { this.name = name }
}

public struct TrustMode {
    public let mode: String
    public init(mode: String) { this.mode = mode }
}

public struct LogFormat {
    public let format: String
    public init(format: String) { this.format = format }
}

public struct RateLimit {
    public let requestsPerMinute: Int64
    public init(requestsPerMinute: Int64) { this.requestsPerMinute = requestsPerMinute }
}

public struct ServerConfig {
    public let host: String
    public let port: UInt16
    public let sessionStore: String
    public let sessionDir: String
    public let authToken: Option<String>
    public let trustMode: String
    public let logLevel: String
    public let logFormat: String
    public let rateLimit: Option<Int64>

    public init(host: String, port: UInt16, sessionStore: String, sessionDir: String,
        authToken: Option<String>, trustMode: String, logLevel: String,
        logFormat: String, rateLimit: Option<Int64>) {
        this.host = host; this.port = port; this.sessionStore = sessionStore
        this.sessionDir = sessionDir; this.authToken = authToken
        this.trustMode = trustMode; this.logLevel = logLevel
        this.logFormat = logFormat; this.rateLimit = rateLimit
    }

    public static func default(): ServerConfig {
        ServerConfig("0.0.0.0", UInt16(8080), "bstorm", "", None, "ask", "", "text", None)
    }
}

public class TomlConfig <: Serializable<TomlConfig> {
    public var agent: ArrayList<TomlAgent> = ArrayList()
    public var provider: ArrayList<TomlProvider> = ArrayList()
    public var server: TomlServer = TomlServer()
    public var logging: TomlLogging = TomlLogging()
    public var mcpServer: ArrayList<TomlMcpServer> = ArrayList()
    public init() {}

    public func serialize(): DataModel {
        DataModelStruct()
            .add(field<ArrayList<TomlAgent>>("agent", this.agent))
            .add(field<ArrayList<TomlProvider>>("provider", this.provider))
            .add(field<TomlServer>("server", this.server))
            .add(field<TomlLogging>("logging", this.logging))
            .add(field<ArrayList<TomlMcpServer>>("mcpServer", this.mcpServer))
    }

    public static func deserialize(dm: DataModel): TomlConfig {
        let dms = match (dm) { case s: DataModelStruct => s; case _ => throw Exception("expected struct") }
        let r = TomlConfig()
        match (dms.get("agent")) {
            case seq: DataModelSeq =>
                for (elem in seq.getItems()) {
                    r.agent.add(TomlAgent.deserialize(elem))
                }
            case _ => ()
        }
        match (dms.get("provider")) {
            case seq: DataModelSeq =>
                for (elem in seq.getItems()) {
                    r.provider.add(TomlProvider.deserialize(elem))
                }
            case _ => ()
        }
        match (dms.get("server")) {
            case dm: DataModelStruct => r.server = TomlServer.deserialize(dm)
            case _ => ()
        }
        match (dms.get("logging")) {
            case dm: DataModelStruct => r.logging = TomlLogging.deserialize(dm)
            case _ => ()
        }
        match (dms.get("mcpServer")) {
            case seq: DataModelSeq =>
                for (elem in seq.getItems()) {
                    r.mcpServer.add(TomlMcpServer.deserialize(elem))
                }
            case _ => ()
        }
        r
    }
}

/**
 * 把 `[[provider.model]]` 声明的窗口装进装配束（端点层）。
 *
 * 未声明的模型沿用模型名层（内置表）与兜底值，运行时会在用到时留一条警告。
 */
public func withTomlProviderModels(spec: HarnessSpec, providers: ArrayList<TomlProvider>): HarnessSpec {
    var out = spec
    for (p in providers) {
        for (m in p.model) {
            // 两个字段各自 <= 0 视为未声明：只写窗口也能只补窗口，完成预算留给 provider 自报
            if (p.name == "" || m.name == "" || (m.contextWindow <= 0 && m.maxTokens <= 0)) {
                continue
            }
            out = out.withModelFacts(p.name, m.name, ModelInfo(m.contextWindow, m.maxTokens))
        }
    }
    out
}

public class TomlServer <: Serializable<TomlServer> {
    public var host: String = "0.0.0.0"
    public var port: Int64 = 8080
    public var sessionStore: String = "bstorm"
    public var sessionDir: String = ""
    public var authToken: String = ""
    public var trustMode: String = "ask"
    public var logLevel: String = ""
    public var logFormat: String = "text"
    public var rateLimit: Int64 = 0
    public init() {}

    public func serialize(): DataModel {
        DataModelStruct()
            .add(field<String>("host", host))
            .add(field<Int64>("port", port))
            .add(field<String>("sessionStore", sessionStore))
            .add(field<String>("sessionDir", sessionDir))
            .add(field<String>("authToken", authToken))
            .add(field<String>("trustMode", trustMode))
            .add(field<String>("logLevel", logLevel))
            .add(field<String>("logFormat", logFormat))
            .add(field<Int64>("rateLimit", rateLimit))
    }

    public static func deserialize(dm: DataModel): TomlServer {
        let dms = match (dm) { case s: DataModelStruct => s; case _ => return TomlServer() }
        let r = TomlServer()
        r.host = match (dms.get("host")) { case s: DataModelString => s.getValue(); case _ => "0.0.0.0" }
        r.port = match (dms.get("port")) { case i: DataModelInt => i.getValue(); case _ => Int64(8080) }
        r.sessionStore = match (dms.get("sessionStore")) { case s: DataModelString => s.getValue(); case _ => "bstorm" }
        r.sessionDir = match (dms.get("sessionDir")) { case s: DataModelString => s.getValue(); case _ => "" }
        r.authToken = match (dms.get("authToken")) { case s: DataModelString => s.getValue(); case _ => "" }
        r.trustMode = match (dms.get("trustMode")) { case s: DataModelString => s.getValue(); case _ => "ask" }
        r.logLevel = match (dms.get("logLevel")) { case s: DataModelString => s.getValue(); case _ => "" }
        r.logFormat = match (dms.get("logFormat")) { case s: DataModelString => s.getValue(); case _ => "text" }
        r.rateLimit = match (dms.get("rateLimit")) { case i: DataModelInt => i.getValue(); case _ => Int64(0) }
        r
    }

    public func toServerConfig(): ServerConfig {
        ServerConfig(
            this.host, UInt16(this.port), this.sessionStore, this.sessionDir,
            if (this.authToken == "") { None } else { Some(this.authToken) },
            this.trustMode, this.logLevel, this.logFormat,
            if (this.rateLimit > 0) { Some(this.rateLimit) } else { None })
    }
}

public class TomlPrune <: Serializable<TomlPrune> {
    public var enabled: Option<Bool> = None
    public var thresholdChars: Option<Int64> = None
    public var headChars: Option<Int64> = None
    public var tailChars: Option<Int64> = None
    public init() {}

    public func serialize(): DataModel {
        let sb = DataModelStruct()
        match (this.enabled) { case Some(v) => sb.add(field<Bool>("enabled", v)); case None => () }
        match (this.thresholdChars) { case Some(v) => sb.add(field<Int64>("thresholdChars", v)); case None => () }
        match (this.headChars) { case Some(v) => sb.add(field<Int64>("headChars", v)); case None => () }
        match (this.tailChars) { case Some(v) => sb.add(field<Int64>("tailChars", v)); case None => () }
        sb
    }

    public static func deserialize(dm: DataModel): TomlPrune {
        let dms = match (dm) { case s: DataModelStruct => s; case _ => return TomlPrune() }
        let r = TomlPrune()
        match (dms.get("enabled")) { case b: DataModelBool => r.enabled = Some(b.getValue()); case _ => () }
        match (dms.get("thresholdChars")) { case i: DataModelInt => r.thresholdChars = Some(i.getValue()); case _ => () }
        match (dms.get("headChars")) { case i: DataModelInt => r.headChars = Some(i.getValue()); case _ => () }
        match (dms.get("tailChars")) { case i: DataModelInt => r.tailChars = Some(i.getValue()); case _ => () }
        r
    }
}

public class TomlCompaction <: Serializable<TomlCompaction> {
    public var enabled: Option<Bool> = None
    // dsh 口径：阈值 = min(W × thresholdRatio, W − maxOutputTokens − headroomTokens)，
    // 保留 = (W − maxOutputTokens) × retainRatio（或绝对 retainTokens）
    public var thresholdRatio: Option<Float64> = None
    public var headroomTokens: Option<Int64> = None
    public var retainRatio: Option<Float64> = None
    public var retainTokens: Option<Int64> = None
    public var maxOverflowRetries: Option<Int64> = None
    public var summaryMaxTokens: Option<Int64> = None
    public var promptTemplate: Option<String> = None
    // [agent.compaction.prune]：工具结果修剪（只在压缩触发后跑，可能省掉摘要）
    public var prune: Option<TomlPrune> = None
    public var outputSchema: DataModel = DataModelNull()
    public var summaryModel: Option<String> = None
    public init() {}

    public func serialize(): DataModel {
        let sb = DataModelStruct()
        match (this.enabled) {
            case Some(v) => sb.add(field<Bool>("enabled", v))
            case None => ()
        }
        match (this.thresholdRatio) {
            case Some(v) => sb.add(field<Float64>("thresholdRatio", v))
            case None => ()
        }
        match (this.headroomTokens) {
            case Some(v) => sb.add(field<Int64>("headroomTokens", v))
            case None => ()
        }
        match (this.retainRatio) {
            case Some(v) => sb.add(field<Float64>("retainRatio", v))
            case None => ()
        }
        match (this.retainTokens) {
            case Some(v) => sb.add(field<Int64>("retainTokens", v))
            case None => ()
        }
        match (this.maxOverflowRetries) {
            case Some(v) => sb.add(field<Int64>("maxOverflowRetries", v))
            case None => ()
        }
        match (this.summaryMaxTokens) {
            case Some(v) => sb.add(field<Int64>("summaryMaxTokens", v))
            case None => ()
        }
        match (this.promptTemplate) {
            case Some(v) => sb.add(field<String>("promptTemplate", v))
            case None => ()
        }
        match (this.prune) {
            case Some(p) => sb.add(Field("prune", p.serialize()))
            case None => ()
        }
        match (this.outputSchema) {
            case _: DataModelNull => ()
            case dm => sb.add(Field("outputSchema", dm))
        }
        match (this.summaryModel) {
            case Some(v) => sb.add(field<String>("summaryModel", v))
            case None => ()
        }
        sb
    }

    public static func deserialize(dm: DataModel): TomlCompaction {
        let dms = match (dm) { case s: DataModelStruct => s; case _ => return TomlCompaction() }
        let r = TomlCompaction()
        match (dms.get("enabled")) {
            case b: DataModelBool => r.enabled = Some(b.getValue())
            case _ => ()
        }
        match (dms.get("thresholdRatio")) {
            case f: DataModelFloat => r.thresholdRatio = Some(f.getValue())
            case i: DataModelInt => r.thresholdRatio = Some(Float64(i.getValue()))
            case _ => ()
        }
        match (dms.get("headroomTokens")) {
            case i: DataModelInt => r.headroomTokens = Some(i.getValue())
            case _ => ()
        }
        match (dms.get("retainRatio")) {
            case f: DataModelFloat => r.retainRatio = Some(f.getValue())
            case i: DataModelInt => r.retainRatio = Some(Float64(i.getValue()))
            case _ => ()
        }
        match (dms.get("retainTokens")) {
            case i: DataModelInt => r.retainTokens = Some(i.getValue())
            case _ => ()
        }
        match (dms.get("maxOverflowRetries")) {
            case i: DataModelInt => r.maxOverflowRetries = Some(i.getValue())
            case _ => ()
        }
        match (dms.get("summaryMaxTokens")) {
            case i: DataModelInt => r.summaryMaxTokens = Some(i.getValue())
            case _ => ()
        }
        match (dms.get("promptTemplate")) {
            case s: DataModelString => r.promptTemplate = Some(s.getValue())
            case _ => ()
        }
        match (dms.get("prune")) {
            case dm: DataModelStruct => r.prune = Some(TomlPrune.deserialize(dm))
            case _ => ()
        }
        match (dms.get("outputSchema")) {
            case dm: DataModelStruct => r.outputSchema = dm
            case dm: DataModelSeq => r.outputSchema = dm
            case _ => ()
        }
        match (dms.get("summaryModel")) {
            case s: DataModelString => r.summaryModel = Some(s.getValue())
            case _ => ()
        }
        r
    }
}

public class TomlAgent <: Serializable<TomlAgent> {
    public var name: String = ""
    public var model: String = ""
    public var systemPrompt: String = ""
    public var description: String = ""
    public var provider: String = ""
    public var tools: ArrayList<String> = ArrayList()
    public var skills: ArrayList<String> = ArrayList()
    public var mcpCooldownTurns: Int64 = 0
    // 单次 run 的最大回合数（每次「模型请求 + 工具批次」记一回合）
    // 采样温度（0 = 确定性输出；评测场景建议调低以降低拒答/漂移方差）
    public var temperature: Float64 = 0.7
    public var maxTurns: Int64 = 20
    // 单条回复的最大输出 token 数（撞上限时按 maxLengthContinuations 续跑）
    public var maxOutputTokens: Int64 = 4096
    // 输出被 token 上限截断后，同一回合内自动续跑的次数上限；0 = 不续跑（截断即回合结束）
    public var maxLengthContinuations: Int64 = 3
    // 收尾前自验次数上限（0 = 关闭）；模型宣布完成时先让它实操核对再收尾
    public var maxVerifyPasses: Int64 = 0
    // 工具呈现模式：native（默认，逐次 JSON Schema）/ ptc（只暴露 run_xisp）/ both
    public var toolPresentation: String = "native"
    // PTC 单次程序的经过时间预算（秒）
    public var ptcTimeoutSeconds: Int64 = 30
    // PTC 单次程序允许的子调用上限
    public var ptcMaxSubCalls: Int64 = 64
    // 单次工具调用的墙钟预算（秒）；0 = 不限时
    public var toolTimeout: Int64 = 30
    // 有副作用（Sequential）工具的单次墙钟预算（秒）；0 = 不限时。
    // 比只读宽：构建/安装这类正常耗时本就长，且这一类的超时意味着「结果未知」
    public var sideEffectToolTimeout: Int64 = 300
    public var compaction: Option<TomlCompaction> = None
    public init() {}

    public func serialize(): DataModel {
        let sb = DataModelStruct()
        sb.add(field<String>("name", name))
        sb.add(field<String>("model", model))
        sb.add(field<String>("systemPrompt", systemPrompt))
        sb.add(field<String>("provider", provider))
        sb.add(field<ArrayList<String>>("tools", tools))
        sb.add(field<ArrayList<String>>("skills", skills))
        sb.add(field<Int64>("mcpCooldownTurns", mcpCooldownTurns))
        sb.add(field<String>("toolPresentation", toolPresentation))
        sb.add(field<Int64>("ptcTimeoutSeconds", ptcTimeoutSeconds))
        sb.add(field<Int64>("ptcMaxSubCalls", ptcMaxSubCalls))
        sb.add(field<Int64>("toolTimeout", toolTimeout))
        sb.add(field<Int64>("sideEffectToolTimeout", sideEffectToolTimeout))
        match (this.compaction) {
            case Some(c) => sb.add(Field("compaction", c.serialize()))
            case None => ()
        }
        sb
    }

    public static func deserialize(dm: DataModel): TomlAgent {
        let dms = match (dm) { case s: DataModelStruct => s; case _ => throw Exception("expected struct") }
        let r = TomlAgent()
        r.name = match (dms.get("name")) { case s: DataModelString => s.getValue(); case _ => "" }
        r.model = match (dms.get("model")) { case s: DataModelString => s.getValue(); case _ => "" }
        r.systemPrompt = match (dms.get("systemPrompt")) { case s: DataModelString => s.getValue(); case _ => "" }
        r.description = match (dms.get("description")) { case s: DataModelString => s.getValue(); case _ => "" }
        r.provider = match (dms.get("provider")) { case s: DataModelString => s.getValue(); case _ => "" }
        match (dms.get("tools")) {
            case seq: DataModelSeq =>
                for (e in seq.getItems()) {
                    match (e) { case s: DataModelString => r.tools.add(s.getValue()); case _ => () }
                }
            case _ => ()
        }
        match (dms.get("skills")) {
            case seq: DataModelSeq =>
                for (e in seq.getItems()) {
                    match (e) { case s: DataModelString => r.skills.add(s.getValue()); case _ => () }
                }
            case _ => ()
        }
        r.mcpCooldownTurns = match (dms.get("mcpCooldownTurns")) { case i: DataModelInt => i.getValue(); case _ => Int64(0) }
        // 缺字段时保持与字段声明一致的默认值：旧配置照常加载，行为不变
        r.toolPresentation = match (dms.get("toolPresentation")) { case s: DataModelString => s.getValue(); case _ => "native" }
        r.ptcTimeoutSeconds = match (dms.get("ptcTimeoutSeconds")) { case i: DataModelInt => i.getValue(); case _ => Int64(30) }
        r.ptcMaxSubCalls = match (dms.get("ptcMaxSubCalls")) { case i: DataModelInt => i.getValue(); case _ => Int64(64) }
        r.toolTimeout = match (dms.get("toolTimeout")) { case i: DataModelInt => i.getValue(); case _ => Int64(30) }
        r.sideEffectToolTimeout = match (dms.get("sideEffectToolTimeout")) { case i: DataModelInt => i.getValue(); case _ => Int64(300) }
        match (dms.get("compaction")) {
            case s: DataModelStruct => r.compaction = Some(TomlCompaction.deserialize(s))
            case _ => ()
        }
        r
    }
}

/**
 * `[[provider.model]]`：某个端点上某个模型的**事实**（当前只有上下文窗口）。
 *
 * 挂在 provider 下而不是 agent 下，是因为窗口是 `(provider, model)` 这一对路由的属性：
 * 同名模型走官方端点和走一个截断过的代理，窗口可以不同；agent 只负责**选**这一对。
 */
public class TomlProviderModel <: Serializable<TomlProviderModel> {
    public var name: String = ""
    // 上下文窗口（token，**含输入与输出**）；<= 0 视为未声明
    public var contextWindow: Int64 = 0
    // 默认完成预算（token）；<= 0 视为未声明（压缩要按 窗口 - 完成预算 - 余量 算消息预算）
    public var maxTokens: Int64 = 0
    public init() {}

    public func serialize(): DataModel {
        DataModelStruct()
            .add(field<String>("name", name))
            .add(field<Int64>("contextWindow", contextWindow))
            .add(field<Int64>("maxTokens", maxTokens))
    }

    public static func deserialize(dm: DataModel): TomlProviderModel {
        let dms = match (dm) { case s: DataModelStruct => s; case _ => return TomlProviderModel() }
        let r = TomlProviderModel()
        r.name = match (dms.get("name")) { case s: DataModelString => s.getValue(); case _ => "" }
        r.contextWindow = match (dms.get("contextWindow")) { case i: DataModelInt => i.getValue(); case _ => Int64(0) }
        r.maxTokens = match (dms.get("maxTokens")) { case i: DataModelInt => i.getValue(); case _ => Int64(0) }
        r
    }
}

public class TomlProvider <: Serializable<TomlProvider> {
    public var name: String = ""
    public var providerType: String = "openai"
    public var baseURL: String = ""
    public var apiKey: String = ""
    public var headers: ArrayList<String> = ArrayList()
    public var extra: DataModel = DataModelNull()
    // 跳过 TLS 证书校验（TrustAll）。仅用于「运行环境取不到系统 CA」的场景
    // （典型：stdx 在 Windows 上拿不到系统证书库，任何 https 都以 unknown CA 失败）
    // 与本地抓包/自签调试；默认 false，保持系统 CA 校验。
    public var skipTlsVerify: Bool = false
    // 本端点上的模型事实（`[[provider.model]]`）
    public var model: ArrayList<TomlProviderModel> = ArrayList()
    public init() {}

    public func serialize(): DataModel {
        DataModelStruct()
            .add(field<String>("name", name))
            .add(field<String>("type", providerType))
            .add(field<String>("baseURL", baseURL))
            .add(field<String>("apiKey", apiKey))
            .add(field<ArrayList<String>>("headers", headers))
            .add(Field("extra", this.extra))
            .add(field<Bool>("skipTlsVerify", skipTlsVerify))
            .add(field<ArrayList<TomlProviderModel>>("model", this.model))
    }

    public static func deserialize(dm: DataModel): TomlProvider {
        let dms = match (dm) { case s: DataModelStruct => s; case _ => throw Exception("expected struct") }
        let r = TomlProvider()
        r.name = match (dms.get("name")) { case s: DataModelString => s.getValue(); case _ => "" }
        r.providerType = match (dms.get("type")) { case s: DataModelString => s.getValue(); case _ => "openai" }
        r.baseURL = match (dms.get("baseURL")) { case s: DataModelString => s.getValue(); case _ => "" }
        r.apiKey = match (dms.get("apiKey")) { case s: DataModelString => s.getValue(); case _ => "" }
        match (dms.get("headers")) {
            case seq: DataModelSeq =>
                for (e in seq.getItems()) {
                    match (e) { case s: DataModelString => r.headers.add(s.getValue()); case _ => () }
                }
            case _ => ()
        }
        r.extra = dms.get("extra")
        match (dms.get("skipTlsVerify")) {
            case b: DataModelBool => r.skipTlsVerify = b.getValue()
            case _ => ()
        }
        match (dms.get("model")) {
            case seq: DataModelSeq =>
                for (e in seq.getItems()) {
                    r.model.add(TomlProviderModel.deserialize(e))
                }
            case _ => ()
        }
        r
    }
}

public func toProviderConfig(tp: TomlProvider): ProviderConfig {
    let extra = HashMap<String, JsonValue>()
    match (JsonValue.fromDataModel(tp.extra)) {
        case JsonValue.Map(m) =>
            for ((k, v) in m) { extra[k] = v }
        case _ => ()
    }
    ProviderConfig(tp.providerType, tp.name, tp.baseURL, tp.apiKey,
        tp.headers, extra, skipTlsVerify: tp.skipTlsVerify)
}

public class TomlMcpServer <: Serializable<TomlMcpServer> {
    public var name: String = ""
    public var transport: String = ""
    public var command: String = ""
    public var url: String = ""
    public var headerList: ArrayList<String> = ArrayList()
    // stdio 子进程环境（数组字符串 "K=V"，同 headers 风格）
    public var envList: ArrayList<String> = ArrayList()
    public init() {}

    public func serialize(): DataModel {
        DataModelStruct()
            .add(field<String>("name", name))
            .add(field<String>("transport", transport))
            .add(field<String>("command", command))
            .add(field<String>("url", url))
            .add(field<ArrayList<String>>("headers", headerList))
            .add(field<ArrayList<String>>("env", envList))
    }

    public static func deserialize(dm: DataModel): TomlMcpServer {
        let dms = match (dm) { case s: DataModelStruct => s; case _ => return TomlMcpServer() }
        let r = TomlMcpServer()
        r.name = match (dms.get("name")) { case s: DataModelString => s.getValue(); case _ => "" }
        r.transport = match (dms.get("transport")) { case s: DataModelString => s.getValue(); case _ => "" }
        r.command = match (dms.get("command")) { case s: DataModelString => s.getValue(); case _ => "" }
        r.url = match (dms.get("url")) { case s: DataModelString => s.getValue(); case _ => "" }
        match (dms.get("headers")) {
            case seq: DataModelSeq =>
                for (e in seq.getItems()) {
                    match (e) { case s: DataModelString => r.headerList.add(s.getValue()); case _ => () }
                }
            case _ => ()
        }
        match (dms.get("env")) {
            case seq: DataModelSeq =>
                for (e in seq.getItems()) {
                    match (e) { case s: DataModelString => r.envList.add(s.getValue()); case _ => () }
                }
            case _ => ()
        }
        r
    }

    public func toMcpServerConfig(): McpServerConfig {
        let hdrs = HashMap<String, String>()
        for (h in this.headerList) { kvAssign(hdrs, h, ":") }
        let envs = HashMap<String, String>()
        for (e in this.envList) { kvAssign(envs, e, "=") }
        if (envs.size > 0) {
            McpServerConfig(this.name, this.transport, this.command, this.url, hdrs, envs)
        } else {
            McpServerConfig(this.name, this.transport, this.command, this.url, hdrs)
        }
    }
}

// "K:V" / "K=V" 列表 → map（K/V 去首尾空白；分隔符缺失的项跳过）
func kvAssign(m: HashMap<String, String>, entry: String, sep: String): Unit {
    let idx = entry.indexOf(sep)
    match (idx) {
        case Some(i) =>
            let key = trimStr(entry[0..i])
            let val = trimStr(entry[(i + 1)..])
            if (key != "") { m[key] = val }
        case None => ()
    }
}

func trimStr(s: String): String {
    var start: Int64 = 0
    var end = s.size - 1
    while (start < s.size && s[start] <= 32) { start++ }
    while (end > start && s[end] <= 32) { end-- }
    if (start == 0 && end == s.size - 1) { s } else { s[start..(end + 1)] }
}

public class TomlLogging <: Serializable<TomlLogging> {
    public var level: String = ""
    public init() {}

    public func serialize(): DataModel {
        DataModelStruct()
            .add(field<String>("level", level))
    }

    public static func deserialize(dm: DataModel): TomlLogging {
        let dms = match (dm) { case s: DataModelStruct => s; case _ => return TomlLogging() }
        let r = TomlLogging()
        r.level = match (dms.get("level")) { case s: DataModelString => s.getValue(); case _ => "" }
        r
    }
}

public func resolveModel(cfgModel: String): String {
    let fromEnv = getEnv("OPENAI_MODEL", "")
    if (cfgModel != "") { cfgModel }
    else if (fromEnv != "") { fromEnv }
    else { "gpt-4o" }
}

func getEnv(key: String, def: String): String {
    match (getVariable(key)) {
        case Some(v) => v
        case None => def
    }
}

public func agentConfigFrom(a: TomlAgent): AgentConfig {
    let compactionCfg: Option<CompactionConfig> = match (a.compaction) {
        case Some(tc) =>
            let cc = CompactionConfig()
            var enabled = cc.enabled
            var ratio = cc.thresholdRatio
            var headroom = cc.headroomTokens
            var retainRatio = cc.retainRatio
            var retain = cc.retainTokens
            var overflowRetries = cc.maxOverflowRetries
            var summaryMax = cc.summaryMaxTokens
            var prune = cc.prune
            var template = cc.promptTemplate
            var schema = cc.outputSchema
            var summaryModel = cc.summaryModel
            match (tc.enabled) { case Some(v) => enabled = v; case None => () }
            match (tc.thresholdRatio) { case Some(v) => ratio = v; case None => () }
            match (tc.headroomTokens) { case Some(v) => headroom = v; case None => () }
            match (tc.retainRatio) { case Some(v) => retainRatio = v; case None => () }
            match (tc.retainTokens) { case Some(v) => retain = Some(v); case None => () }
            match (tc.maxOverflowRetries) { case Some(v) => overflowRetries = v; case None => () }
            match (tc.summaryMaxTokens) { case Some(v) => summaryMax = v; case None => () }
            match (tc.prune) {
                case Some(tp) =>
                    let def = ToolResultPruneConfig()
                    var pEnabled = def.enabled
                    var pThreshold = def.thresholdChars
                    var pHead = def.headChars
                    var pTail = def.tailChars
                    match (tp.enabled) { case Some(v) => pEnabled = v; case None => () }
                    match (tp.thresholdChars) { case Some(v) => pThreshold = v; case None => () }
                    match (tp.headChars) { case Some(v) => pHead = v; case None => () }
                    match (tp.tailChars) { case Some(v) => pTail = v; case None => () }
                    prune = Some(ToolResultPruneConfig(pEnabled, pThreshold, pHead, pTail))
                case None => ()
            }
            match (tc.promptTemplate) { case Some(v) => template = v; case None => () }
            match (tc.summaryModel) { case Some(v) => summaryModel = Some(v); case None => () }
            match (tc.outputSchema) {
                case dm: DataModelStruct => schema = Some(JsonValue.fromDataModel(dm))
                case dm: DataModelSeq => schema = Some(JsonValue.fromDataModel(dm))
                case _ => ()
            }
            Some(CompactionConfig(enabled, ratio, headroom, retainRatio, retain, overflowRetries,
                template, schema, summaryModel, summaryMaxTokens: summaryMax, prune: prune))
        case None => None
    }
    AgentConfig(
        a.name,
        if (a.description == "") { None } else { Some(a.description) },
        a.systemPrompt, None,
        a.model,
        if (a.provider == "") { None } else { Some(a.provider) },
        a.tools, a.skills, a.mcpCooldownTurns,
        budgetOrDefault(a.maxTurns, UInt32(20)), temperatureOrDefault(a.temperature, Float32(0.7)), budgetOrDefault(a.maxOutputTokens, UInt32(4096)), None,
        true, compactionCfg, UInt32(50),
        toolBudgetSeconds(a.toolTimeout, UInt32(30)), UInt32(0),
        ArrayList<String>(), None, 0, 0,
        toolPresentation: ToolPresentationMode.fromString(a.toolPresentation),
        ptcTimeoutSeconds: ptcBudget(a.ptcTimeoutSeconds, UInt32(30)),
        ptcMaxSubCalls: ptcBudget(a.ptcMaxSubCalls, UInt32(64)),
        sideEffectToolTimeout: toolBudgetSeconds(a.sideEffectToolTimeout, UInt32(300)),
        maxLengthContinuations: continuationBudget(a.maxLengthContinuations, UInt32(3)),
        maxVerifyPasses: continuationBudget(a.maxVerifyPasses, UInt32(0)))
}

/**
 * 把 TOML 里的整数收束成合法的 UInt32 预算值。
 *
 * 配置写错（0、负数、超出范围）时回落到默认值，而不是让构造抛异常——
 * 与 `ToolPresentationMode.fromString` 的态度一致：笔误应当退化为「保持现状」，
 * 不该让整个 Agent 起不来。
 */
// 与 ptcBudget 同义，名字直白些：<=0 或越界即回落默认值
func budgetOrDefault(value: Int64, fallback: UInt32): UInt32 {
    if (value <= 0 || value > 4294967295) {
        return fallback
    }
    UInt32(value)
}

// 温度允许 0（确定性输出），只拦负数与超出常见上限（2.0）的笔误
func temperatureOrDefault(value: Float64, fallback: Float32): Float32 {
    if (value < 0.0 || value > 2.0) {
        return fallback
    }
    Float32(value)
}

// 续跑预算允许 0（= 不续跑，保持「截断即回合结束」），只拦负数与越界
func continuationBudget(value: Int64, fallback: UInt32): UInt32 {
    if (value < 0 || value > 4294967295) {
        return fallback
    }
    UInt32(value)
}

func ptcBudget(value: Int64, fallback: UInt32): UInt32 {
    if (value <= 0 || value > 4294967295) {
        return fallback
    }
    UInt32(value)
}

/**
 * 工具预算秒数：与 {@link ptcBudget} 同样是收束，但 **0 是合法值**（不限时）。
 *
 * 不限时是使用者的显式选择，不能被「像笔误就回落」的规则悄悄改掉；
 * 这里只挡负数与溢出。
 */
func toolBudgetSeconds(value: Int64, fallback: UInt32): UInt32 {
    if (value < 0 || value > 4294967295) {
        return fallback
    }
    UInt32(value)
}

public func loadToml(path: String): TomlConfig {
    let p = Path(path)
    if (!exists(p)) { return TomlConfig() }
    try { unmarshal<TomlConfig>(path) } catch (_) { TomlConfig() }
}
