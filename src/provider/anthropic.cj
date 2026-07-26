package atelier.provider

import stdx.net.http.*
import stdx.net.tls.*
import stdx.log.LogLevel
import stdx.log.NoopLogger
import stdx.encoding.url.URL
import jsonvalue.*
import std.collection.*
import atelier.message.*
import atelier.event.EventStream
import std.core.Duration
import atelier.util.toJsonString
import atelier.util.fromJsonString
import stdx.encoding.json.stream.*

public class AnthropicProvider <: Provider {
    private let provName: String
    private let baseURL: String
    private let apiKey: String
    private let apiHost: String
    private let httpClient: Client

    public init(name: String, baseURL: String, apiKey: String) {
        this.provName = name
        this.baseURL = baseURL.trimEnd('/')
        this.apiKey = apiKey
        this.apiHost = extractHost(baseURL)
        let httpLogger = NoopLogger()
        httpLogger.level = LogLevel.OFF
        let b = ClientBuilder().logger(httpLogger)
            .readTimeout(120 * Duration.second)
        if (baseURL.startsWith("https://")) {
            var tlsCfg = TlsClientConfig()
            tlsCfg.serverName = Some(this.apiHost)
            b.tlsConfig(tlsCfg)
        }
        this.httpClient = b.build()
    }

    public func name(): String { this.provName }

    public func chat(req: ChatRequest): ChatResponse {
        let bodyJson = buildAnthropicRequest(req, false)
        let httpReq = HttpRequestBuilder()
            .url(this.baseURL + "/v1/messages")
            .header("Content-Type", "application/json")
            .header("x-api-key", this.apiKey)
            .header("anthropic-version", "2023-06-01")
            .body(bodyJson)
            .post()
            .build()
        let resp = this.httpClient.send(httpReq)
        if (resp.status != 200) {
            let errBody = readAll(resp.body)
            throw Exception("Anthropic API error [" + resp.status.toString() + "]: " + errBody)
        }
        let json = readAll(resp.body)
        let aResp = fromJsonString<AnthropicResponse>(json)
        let content = buildAnthropicContent(aResp.content)
        let stopReason = anthropicStopReason(aResp.stopReason)
        ChatResponse(AssistantMessage(
            content, aResp.model, this.provName,
            stopReason,
            TokenUsage(aResp.usage.inputTokens, aResp.usage.outputTokens), 0))
    }

    public func chatStreaming(req: ChatRequest): EventStream<ChatDelta, AssistantMessage> {
        let stream = EventStream<ChatDelta, AssistantMessage>()
        let bodyJson = buildAnthropicRequest(req, true)
        spawn {
            doAnthropicStream(this.httpClient, this.baseURL, this.apiKey, this.provName, bodyJson, stream)
        }
        stream
    }
}

func buildAnthropicRequest(req: ChatRequest, stream: Bool): String {
    let obj = HashMap<String, JsonValue>()
    obj["model"] = JsonValue.String(req.model)
    obj["max_tokens"] = JsonValue.Number(Float64(req.maxTokens))
    obj["stream"] = JsonValue.Boolean(stream)
    if (req.temperature >= 0.0) {
        obj["temperature"] = JsonValue.Number(req.temperature)
    }
    // System prompt
    var systemMsgs = ArrayList<String>()
    var msgs = ArrayList<JsonValue>()
    for (m in req.messages) {
        match (m) {
            case um: UserMessage =>
                let text = contentToText(um.content)
                // System prompt is embedded as user message, extract it
                if (text.startsWith("[System]: ")) {
                    systemMsgs.add(text[10..])
                } else {
                    msgs.add(messageToAnthropic("user", text))
                }
            case am: AssistantMessage =>
                let text = contentToText(am.content)
                let tcs = am.toolCalls()
                if (tcs.size > 0) {
                    let blocks = ArrayList<JsonValue>()
                    if (text != "") {
                        let tb = HashMap<String, JsonValue>()
                        tb["type"] = JsonValue.String("text")
                        tb["text"] = JsonValue.String(text)
                        blocks.add(JsonValue.Map(tb))
                    }
                    for (tc in tcs) {
                        let tcb = HashMap<String, JsonValue>()
                        tcb["type"] = JsonValue.String("tool_use")
                        tcb["id"] = JsonValue.String(tc.id)
                        tcb["name"] = JsonValue.String(tc.name)
                        tcb["input"] = tc.args
                        blocks.add(JsonValue.Map(tcb))
                    }
                    let msgObj = HashMap<String, JsonValue>()
                    msgObj["role"] = JsonValue.String("assistant")
                    msgObj["content"] = JsonValue.Array(blocks)
                    msgs.add(JsonValue.Map(msgObj))
                } else {
                    msgs.add(messageToAnthropic("assistant", text))
                }
            case tm: ToolResultMessage =>
                let text = contentToText(tm.content)
                let block = HashMap<String, JsonValue>()
                block["type"] = JsonValue.String("tool_result")
                block["tool_use_id"] = JsonValue.String(tm.toolCallId)
                block["content"] = JsonValue.String(text)
                let msgObj = HashMap<String, JsonValue>()
                msgObj["role"] = JsonValue.String("user")
                msgObj["content"] = JsonValue.Array(ArrayList<JsonValue>([JsonValue.Map(block)]))
                msgs.add(JsonValue.Map(msgObj))
            case cm: CompactionMessage =>
                msgs.add(messageToAnthropic("user", "[Summary: " + cm.summary + "]"))
            case _ => ()
        }
    }
    if (systemMsgs.size > 0) {
        let sb = StringBuilder()
        for (i in 0..systemMsgs.size) {
            if (i > 0) { sb.append("\n") }
            sb.append(systemMsgs[Int64(i)])
        }
        obj["system"] = JsonValue.String(sb.toString())
    }
    obj["messages"] = JsonValue.Array(msgs)
    // Tools
    if (req.tools.size > 0) {
        let tools = ArrayList<JsonValue>()
        for (t in req.tools) {
            let toolObj = HashMap<String, JsonValue>()
            toolObj["name"] = JsonValue.String(t.name)
            if (t.description != "") { toolObj["description"] = JsonValue.String(t.description) }
            toolObj["input_schema"] = t.parameters
            tools.add(JsonValue.Map(toolObj))
        }
        obj["tools"] = JsonValue.Array(tools)
    }
    toJsonString(JsonValue.Map(obj))
}

func messageToAnthropic(role: String, text: String): JsonValue {
    let obj = HashMap<String, JsonValue>()
    obj["role"] = JsonValue.String(role)
    obj["content"] = JsonValue.String(text)
    JsonValue.Map(obj)
}

func doAnthropicStream(client: Client, baseURL: String, apiKey: String, provName: String,
    bodyJson: String, stream: EventStream<ChatDelta, AssistantMessage>): Unit {
    try {
        let httpReq = HttpRequestBuilder()
            .url(baseURL + "/v1/messages")
            .header("Content-Type", "application/json")
            .header("x-api-key", apiKey)
            .header("anthropic-version", "2023-06-01")
            .body(bodyJson)
            .post()
            .build()
        let resp = client.send(httpReq)
        if (resp.status != 200) {
            let errBody = readAll(resp.body)
            stream.setError(Exception("Anthropic API error [" + resp.status.toString() + "]: " + errBody))
            return
        }
        var contentBuilder = StringBuilder()
        var model = ""
        var stopReason = ""
        var inputTokens: Int64 = 0
        var outputTokens: Int64 = 0
        var contentIndex: Int64 = 0
        let buf = Array<Byte>(4096, repeat: 0)
        var lineBuf = ArrayList<Byte>()

        while (true) {
            let n: Int64
            try { n = resp.body.read(buf) } catch (_) { break }
            if (n <= 0) { break }
            for (j in 0..n) {
                let b = buf[Int64(j)]
                if (b == 10) {
                    let raw = Array<Byte>(lineBuf.size, repeat: 0)
                    for (i in 0..lineBuf.size) { raw[i] = lineBuf[i] }
                    let line = String.fromUtf8(raw)
                    lineBuf.clear()
                    if (line == "") { continue }
                    if (line.startsWith("event: ")) {
                        continue
                    }
                    if (line.startsWith("data: ")) {
                        let data = line[6..]
                        if (data == "[DONE]") { break }
                        let ev = fromJsonString<AnthropicStreamEvent>(data)
                        match (ev.eventType) {
                            case "message_start" =>
                                model = ev.message.model
                                inputTokens = ev.message.usage.inputTokens
                            case "content_block_delta" =>
                                if (ev.delta.deltaType == "text_delta") {
                                    contentBuilder.append(ev.delta.text)
                                    stream.emit(ChatDelta(ev.delta.text, "", Option<StopReason>.None))
                                }
                            case "message_delta" =>
                                stopReason = ev.delta.stopReason
                                outputTokens = ev.usage.outputTokens
                            case "message_stop" => break
                            case _ => ()
                        }
                    }
                } else {
                    lineBuf.add(b)
                }
            }
        }
        let finalContent = ContentList.ofText(contentBuilder.toString())
        let finalStop = anthropicStopReason(stopReason)
        let assistantMsg = AssistantMessage(
            finalContent, model, provName,
            finalStop, TokenUsage(inputTokens, outputTokens), 0)
        stream.setResult(assistantMsg)
    } catch (e: Exception) {
        stream.setError(e)
    }
}

func extractHost(url: String): String {
    let start = if (url.startsWith("https://")) { 8 } else if (url.startsWith("http://")) { 7 } else { 0 }
    match (url.indexOf("/", Int64(start))) {
        case Some(idx) => url[start..idx]
        case None => url[start..]
    }
}

func anthropicStopReason(s: String): StopReason {
    match (s) {
        case "end_turn" => StopReason.EndTurn
        case "tool_use" => StopReason.ToolUse
        case "max_tokens" => StopReason.Length
        case _ => StopReason.EndTurn
    }
}

func buildAnthropicContent(content: ArrayList<AnthropicContentBlock>): ContentList {
    let blocks = ArrayList<ContentBlock>()
    for (cb in content) {
    match (cb.blockType) {
        case "text" =>
            if (cb.text != "") { blocks.add(ContentBlock.TextBlock(cb.text)) }
        case "tool_use" =>
            blocks.add(ContentBlock.ToolCall(ToolCallBlock(cb.id, cb.name, cb.input)))
        case _ => ()
    }
    }
    ContentList(blocks)
}

// --- Types ---

public struct AnthropicResponse <: JsonDeserializable<AnthropicResponse> {
    public var id: String = ""
    public var model: String = ""
    public var role: String = ""
    public var content: ArrayList<AnthropicContentBlock> = ArrayList()
    public var stopReason: String = ""
    public var usage: AnthropicUsage = AnthropicUsage()

    public static func fromJson(r: JsonReader): AnthropicResponse {
        var res = AnthropicResponse()
        r.startObject()
        while (r.peek() != EndObject) {
            match (r.readName()) {
                case "id" => res.id = r.readValue<String>()
                case "model" => res.model = r.readValue<String>()
                case "role" => res.role = r.readValue<String>()
                case "content" => res.content = r.readValue<ArrayList<AnthropicContentBlock>>()
                case "stop_reason" => res.stopReason = r.readValue<String>()
                case "usage" => res.usage = r.readValue<AnthropicUsage>()
                case _ => r.skip()
            }
        }
        r.endObject()
        res
    }
}

public struct AnthropicContentBlock <: JsonDeserializable<AnthropicContentBlock> {
    public var blockType: String = ""
    public var text: String = ""
    public var id: String = ""
    public var name: String = ""
    public var input: JsonValue = JsonValue.Null

    public static func fromJson(r: JsonReader): AnthropicContentBlock {
        var res = AnthropicContentBlock()
        r.startObject()
        while (r.peek() != EndObject) {
            match (r.readName()) {
                case "type" => res.blockType = r.readValue<String>()
                case "text" => res.text = r.readValue<String>()
                case "id" => res.id = r.readValue<String>()
                case "name" => res.name = r.readValue<String>()
                case "input" => res.input = r.readValue<JsonValue>()
                case _ => r.skip()
            }
        }
        r.endObject()
        res
    }
}

public struct AnthropicUsage <: JsonDeserializable<AnthropicUsage> {
    public var inputTokens: Int64 = 0
    public var outputTokens: Int64 = 0

    public static func fromJson(r: JsonReader): AnthropicUsage {
        var res = AnthropicUsage()
        r.startObject()
        while (r.peek() != EndObject) {
            match (r.readName()) {
                case "input_tokens" => res.inputTokens = r.readValue<Int64>()
                case "output_tokens" => res.outputTokens = r.readValue<Int64>()
                case _ => r.skip()
            }
        }
        r.endObject()
        res
    }
}

public struct AnthropicStreamEvent <: JsonDeserializable<AnthropicStreamEvent> {
    public var eventType: String = ""
    public var message: AnthropicStreamMessage = AnthropicStreamMessage()
    public var delta: AnthropicStreamDelta = AnthropicStreamDelta()
    public var usage: AnthropicUsage = AnthropicUsage()

    public static func fromJson(r: JsonReader): AnthropicStreamEvent {
        var res = AnthropicStreamEvent()
        r.startObject()
        while (r.peek() != EndObject) {
            match (r.readName()) {
                case "type" => res.eventType = r.readValue<String>()
                case "message" => res.message = r.readValue<AnthropicStreamMessage>()
                case "delta" => res.delta = r.readValue<AnthropicStreamDelta>()
                case "usage" => res.usage = r.readValue<AnthropicUsage>()
                case _ => r.skip()
            }
        }
        r.endObject()
        res
    }
}

public struct AnthropicStreamMessage <: JsonDeserializable<AnthropicStreamMessage> {
    public var id: String = ""
    public var model: String = ""
    public var usage: AnthropicUsage = AnthropicUsage()

    public static func fromJson(r: JsonReader): AnthropicStreamMessage {
        var res = AnthropicStreamMessage()
        r.startObject()
        while (r.peek() != EndObject) {
            match (r.readName()) {
                case "id" => res.id = r.readValue<String>()
                case "model" => res.model = r.readValue<String>()
                case "usage" => res.usage = r.readValue<AnthropicUsage>()
                case _ => r.skip()
            }
        }
        r.endObject()
        res
    }
}

public struct AnthropicStreamDelta <: JsonDeserializable<AnthropicStreamDelta> {
    public var deltaType: String = ""
    public var text: String = ""
    public var stopReason: String = ""

    public static func fromJson(r: JsonReader): AnthropicStreamDelta {
        var res = AnthropicStreamDelta()
        r.startObject()
        while (r.peek() != EndObject) {
            match (r.readName()) {
                case "type" => res.deltaType = r.readValue<String>()
                case "text" => res.text = r.readValue<String>()
                case "stop_reason" => res.stopReason = r.readValue<String>()
                case _ => r.skip()
            }
        }
        r.endObject()
        res
    }
}
