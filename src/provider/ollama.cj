package atelier.provider

import stdx.net.http.*
import stdx.net.tls.*
import stdx.log.*
import jsonvalue.*
import std.collection.*
import atelier.message.*
import atelier.event.EventStream
import atelier.util.{toJsonString, fromJsonString}
import stdx.encoding.json.stream.*
import stdx.encoding.url.*
import std.core.Duration
import stdx.log.*

public class OllamaProvider <: Provider {
    private let provName: String
    private let baseURL: String
    private let httpClient: Client

    public init(name: String, baseURL: String) {
        this.provName = name
        this.baseURL = baseURL.trimEnd('/')
        let httpLogger = NoopLogger()
        httpLogger.level = LogLevel.OFF
        let b = ClientBuilder().logger(httpLogger)
            .readTimeout(60 * Duration.second)
        if (baseURL.startsWith("https://")) {
            var tlsCfg = TlsClientConfig()
            let parsed = URL.parse(baseURL)
            tlsCfg.serverName = Some(parsed.hostName)
            b.tlsConfig(tlsCfg)
        }
        this.httpClient = b.build()
    }

    public func name(): String { this.provName }

    public func chat(req: ChatRequest): ChatResponse {
        let bodyJson = buildOllamaRequest(req, false)
        let httpReq = HttpRequestBuilder()
            .url(this.baseURL + "/api/chat")
            .header("Content-Type", "application/json")
            .body(bodyJson)
            .post()
            .build()
        let resp = this.httpClient.send(httpReq)
        if (resp.status != 200) {
            throw Exception("Ollama API error [" + resp.status.toString() + "]: " + readAll(resp.body))
        }
        let json = readAll(resp.body)
        let oResp = fromJsonString<OllamaResponse>(json)
        ChatResponse(AssistantMessage(
            ContentList.ofText(oResp.message.content),
            oResp.model, this.provName,
            ollamaDoneReason(oResp.doneReason),
            TokenUsage(oResp.promptEvalCount, oResp.evalCount), 0))
    }

    public func chatStreaming(req: ChatRequest): EventStream<ChatDelta, AssistantMessage> {
        let stream = EventStream<ChatDelta, AssistantMessage>()
        let bodyJson = buildOllamaRequest(req, true)
        spawn {
            doOllamaStream(this.httpClient, this.baseURL, bodyJson, stream)
        }
        stream
    }
}

func buildOllamaRequest(req: ChatRequest, stream: Bool): String {
    let msgs = messagesToOllama(req.messages)
    let obj = HashMap<String, JsonValue>()
    obj["model"] = JsonValue.String(req.model)
    obj["messages"] = JsonValue.Array(msgs)
    obj["stream"] = JsonValue.Boolean(stream)
    if (req.temperature >= 0.0) {
        let opts = HashMap<String, JsonValue>()
        opts["temperature"] = JsonValue.Number(req.temperature)
        obj["options"] = JsonValue.Map(opts)
    }
    toJsonString(JsonValue.Map(obj))
}

func messagesToOllama(msgs: ArrayList<Message>): ArrayList<JsonValue> {
    let result = ArrayList<JsonValue>()
    for (m in msgs) {
        let obj = HashMap<String, JsonValue>()
        match (m) {
            case um: UserMessage =>
                obj["role"] = JsonValue.String("user")
                obj["content"] = JsonValue.String(contentToText(um.content))
            case am: AssistantMessage =>
                obj["role"] = JsonValue.String("assistant")
                obj["content"] = JsonValue.String(contentToText(am.content))
            case tm: ToolResultMessage =>
                obj["role"] = JsonValue.String("tool")
                obj["content"] = JsonValue.String(contentToText(tm.content))
            case cm: CompactionMessage =>
                obj["role"] = JsonValue.String("user")
                obj["content"] = JsonValue.String("[Summary: " + cm.summary + "]")
            case _ => ()
        }
        result.add(JsonValue.Map(obj))
    }
    result
}

func doOllamaStream(client: Client, baseURL: String,
    bodyJson: String, stream: EventStream<ChatDelta, AssistantMessage>): Unit {
    try {
        let httpReq = HttpRequestBuilder()
            .url(baseURL + "/api/chat")
            .header("Content-Type", "application/json")
            .body(bodyJson)
            .post()
            .build()
        let resp = client.send(httpReq)
        if (resp.status != 200) {
            let errBody = readAll(resp.body)
            stream.setError(Exception("Ollama API error [" + resp.status.toString() + "]: " + errBody))
            return
        }
        var contentBuilder = StringBuilder()
        var done = false
        var doneReason = ""
        var model = ""
        let buf = Array<Byte>(4096, repeat: 0)

        while (!done) {
            let n: Int64
            try { n = resp.body.read(buf) } catch (_) { break }
            if (n <= 0) { break }
            var lineBuf = ArrayList<Byte>()
            for (j in 0..n) {
                let b = buf[Int64(j)]
                if (b == 10) {
                    if (lineBuf.size == 0) { continue }
                    let raw = Array<Byte>(lineBuf.size, repeat: 0)
                    for (i in 0..lineBuf.size) { raw[i] = lineBuf[i] }
                    let line = String.fromUtf8(raw)
                    lineBuf.clear()
                    if (line == "") { continue }
                    let chunk = fromJsonString<OllamaStreamChunk>(line)
                    let msg = chunk.message
                    if (msg.content != "") {
                        contentBuilder.append(msg.content)
                    }
                    let sReason: Option<StopReason> = if (chunk.done) {
                        done = true
                        doneReason = chunk.doneReason
                        model = chunk.model
                        Some(ollamaDoneReason(chunk.doneReason))
                    } else {
                        Option<StopReason>.None
                    }
                    stream.emit(ChatDelta(msg.content, msg.thinking, sReason))
                } else {
                    lineBuf.add(b)
                }
            }
        }
        let finalStop = if (doneReason != "") { ollamaDoneReason(doneReason) } else { StopReason.EndTurn }
        let finalText = contentBuilder.toString()
        let assistantMsg = AssistantMessage(
            ContentList.ofText(finalText),
            model, "", finalStop, TokenUsage(0, 0), 0)
        stream.setResult(assistantMsg)
    } catch (e: Exception) {
        stream.setError(e)
    }
}

func ollamaDoneReason(s: String): StopReason {
    match (s) {
        case "stop" => StopReason.EndTurn
        case "length" => StopReason.Length
        case "error" => StopReason.Error
        case _ => StopReason.EndTurn
    }
}

public struct OllamaResponse <: JsonDeserializable<OllamaResponse> {
    public var model: String = ""
    public var message: OllamaResponseMessage = OllamaResponseMessage()
    public var doneReason: String = ""
    public var done: Bool = false
    public var promptEvalCount: Int64 = 0
    public var evalCount: Int64 = 0

    public static func fromJson(r: JsonReader): OllamaResponse {
        var res = OllamaResponse()
        r.startObject()
        while (r.peek() != EndObject) {
            match (r.readName()) {
                case "model" => res.model = r.readValue<String>()
                case "message" => res.message = r.readValue<OllamaResponseMessage>()
                case "done_reason" => res.doneReason = r.readValue<String>()
                case "done" => res.done = r.readValue<Bool>()
                case "prompt_eval_count" => res.promptEvalCount = r.readValue<Int64>()
                case "eval_count" => res.evalCount = r.readValue<Int64>()
                case _ => r.skip()
            }
        }
        r.endObject()
        res
    }
}

public struct OllamaResponseMessage <: JsonDeserializable<OllamaResponseMessage> {
    public var role: String = ""
    public var content: String = ""

    public static func fromJson(r: JsonReader): OllamaResponseMessage {
        var res = OllamaResponseMessage()
        r.startObject()
        while (r.peek() != EndObject) {
            match (r.readName()) {
                case "role" => res.role = r.readValue<String>()
                case "content" => res.content = r.readValue<String>()
                case _ => r.skip()
            }
        }
        r.endObject()
        res
    }
}

public struct OllamaStreamChunk <: JsonDeserializable<OllamaStreamChunk> {
    public var model: String = ""
    public var message: OllamaStreamMessage = OllamaStreamMessage()
    public var doneReason: String = ""
    public var done: Bool = false

    public static func fromJson(r: JsonReader): OllamaStreamChunk {
        var res = OllamaStreamChunk()
        r.startObject()
        while (r.peek() != EndObject) {
            match (r.readName()) {
                case "model" => res.model = r.readValue<String>()
                case "message" => res.message = r.readValue<OllamaStreamMessage>()
                case "done_reason" => res.doneReason = r.readValue<String>()
                case "done" => res.done = r.readValue<Bool>()
                case _ => r.skip()
            }
        }
        r.endObject()
        res
    }
}

public struct OllamaStreamMessage <: JsonDeserializable<OllamaStreamMessage> {
    public var role: String = ""
    public var content: String = ""
    public var thinking: String = ""

    public static func fromJson(r: JsonReader): OllamaStreamMessage {
        var res = OllamaStreamMessage()
        r.startObject()
        while (r.peek() != EndObject) {
            match (r.readName()) {
                case "role" => res.role = r.readValue<String>()
                case "content" => res.content = r.readValue<String>()
                case "thinking" => res.thinking = r.readValue<String>()
                case _ => r.skip()
            }
        }
        r.endObject()
        res
    }
}


