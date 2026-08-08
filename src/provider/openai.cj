package atelier.provider

import stdx.net.http.*
import stdx.net.tls.*
import stdx.encoding.url.*
import jsonvalue.*
import stdx.log.*
import std.io.InputStream
import std.collection.*
import atelier.message.*
import atelier.event.EventStream
import atelier.util.{toJsonString, fromJsonString}

public class OpenAIProvider <: Provider {
    private let provName: String
    private let baseURL: String
    private let apiKey: String
    private let headers: ArrayList<String>
    private let httpClient: Client

    public init(name: String, baseURL: String, apiKey: String) {
        this(name, baseURL, apiKey, ArrayList<String>())
    }

    public init(name: String, baseURL: String, apiKey: String, headers: ArrayList<String>) {
        this.provName = name
        this.baseURL = baseURL.trimEnd('/')
        this.apiKey = apiKey
        this.headers = headers
        let httpLogger = NoopLogger()
        httpLogger.level = LogLevel.OFF
        let b = ClientBuilder().logger(httpLogger)
            .readTimeout(30 * Duration.second)
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
        let oaiReq = buildRequest(req, false)
        let bodyJson = toJsonString(oaiReq)
        let b = HttpRequestBuilder()
        b.url(this.baseURL + "/chat/completions")
        b.header("Content-Type", "application/json")
        b.header("Authorization", "Bearer " + this.apiKey)
        applyExtraHeaders(b, this.headers)
        b.body(bodyJson)
        b.post()
        let httpReq = b.build()
        let resp = this.httpClient.send(httpReq)
        if (resp.status != 200) {
            throw Exception("OpenAI API error [" + resp.status.toString() + "]: " + readAll(resp.body))
        }
        let json = readAll(resp.body)
        let oaiResp = fromJsonString<OpenAIResponse>(json)
        if (oaiResp.choices.size == 0) { throw Exception("No choices in response") }
        let choice = oaiResp.choices[0]
        ChatResponse(AssistantMessage(
            ContentList.ofText(choice.message.content),
            "", "", stopReasonFromStr(choice.finishReason),
            TokenUsage(oaiResp.usage.promptTokens, oaiResp.usage.completionTokens), 0,
            choice.message.reasoningContent))
    }

    public func chatStreaming(req: ChatRequest): EventStream<ChatDelta, AssistantMessage> {
        let stream = EventStream<ChatDelta, AssistantMessage>()
        let oaiReq = buildRequest(req, true)
        let bodyJson = toJsonString(oaiReq)
        spawn {
            doStreamRequest(this.httpClient, this.baseURL, this.apiKey, this.headers, bodyJson, stream)
        }
        stream
    }
}

func buildRequest(req: ChatRequest, stream: Bool): OpenAIRequest {
    OpenAIRequest(req.model, messagesToOpenAI(req.messages), stream,
        req.temperature, req.maxTokens, req.reasoningEffort,
        req.tools)
}

func doStreamRequest(client: Client, baseURL: String, apiKey: String, headers: ArrayList<String>,
    bodyJson: String, stream: EventStream<ChatDelta, AssistantMessage>): Unit {
    try {
        let b = HttpRequestBuilder()
        b.url(baseURL + "/chat/completions")
        b.header("Content-Type", "application/json")
        b.header("Authorization", "Bearer " + apiKey)
        applyExtraHeaders(b, headers)
        b.body(bodyJson)
        b.post()
        let httpReq = b.build()
        let resp = client.send(httpReq)
        if (resp.status != 200) {
            let errBody = readAll(resp.body)
            stream.setError(Exception("OpenAI API error [" + resp.status.toString() + "]: " + errBody))
            return
        }
        var contentBuilder = StringBuilder()
        var reasoningBuilder = StringBuilder()
        var dataBuf = ArrayList<String>()
        var buf = Array<Byte>(4096, repeat: 0)
        var lineBuf = ArrayList<Byte>()
        var streamDone = false
        var lastFinishReason = ""
        var toolCallAccum = ArrayList<JsonValue>()

        while (!streamDone) {
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
                    if (line.startsWith("data:")) {
                        dataBuf.add(line[6..])
                        continue
                    }
                    if (line == "") {
                        if (dataBuf.size == 0) { continue }
                        let data = StringBuilder()
                        for (i in 0..dataBuf.size) {
                            data.append(dataBuf[i])
                            if (i < dataBuf.size - 1) { data.append("\n") }
                        }
                        let dataStr = data.toString()
                        dataBuf.clear()
                        if (dataStr == "[DONE]") {
                            streamDone = true
                            break
                        }
                        let chunk = fromJsonString<OpenAIStreamChunk>(dataStr)
                        if (chunk.choices.size == 0) { continue }
                        let sc = chunk.choices[0]
                        contentBuilder.append(sc.delta.content)
                        reasoningBuilder.append(sc.delta.reasoningContent)
                        let sReason: Option<StopReason> = match (sc.finishReason) {
                            case Some(s) =>
                                lastFinishReason = s
                                streamDone = true
                                Some(stopReasonFromStr(s))
                            case None => Option<StopReason>.None
                        }
                        stream.emit(ChatDelta(sc.delta.content, sc.delta.reasoningContent, sReason))
                        if (sc.delta.toolCalls.size > 0) {
                            mergeToolCalls(toolCallAccum, sc.delta.toolCalls)
                        }
                    }
                } else {
                    lineBuf.add(b)
                }
            }
        }
        let finalText = contentBuilder.toString()
        let reasoningText = reasoningBuilder.toString()
        let finalStopReason = if (lastFinishReason != "") { stopReasonFromStr(lastFinishReason) } else { StopReason.EndTurn }
        let assistantMsg = AssistantMessage(
            buildContent(finalText, toolCallAccum), "", "",
            finalStopReason, TokenUsage(0, 0), 0,
            reasoningText)
        stream.setResult(assistantMsg)
    } catch (e: Exception) {
        stream.setError(e)
    }
}

func messagesToOpenAI(msgs: ArrayList<Message>): ArrayList<OpenAIMessage> {
    let result = ArrayList<OpenAIMessage>()
    for (m in msgs) {
        match (m) {
            case um: UserMessage =>
                result.add(OpenAIMessage("user", contentToText(um.content), Option<String>.None, "", ArrayList<JsonValue>()))
            case am: AssistantMessage =>
                let rc: Option<String> = if (am.reasoningContent != "") { Some(am.reasoningContent) } else { Option<String>.None }
                let tcs = ArrayList<JsonValue>()
                for (tc in am.toolCalls()) {
                    let fn = HashMap<String, JsonValue>()
                    fn.add("name", JsonValue.String(tc.name))
                    fn.add("arguments", JsonValue.String(toJsonString(tc.args)))
                    let item = HashMap<String, JsonValue>()
                    item.add("id", JsonValue.String(tc.id))
                    item.add("type", JsonValue.String("function"))
                    item.add("function", JsonValue.Map(fn))
                    tcs.add(JsonValue.Map(item))
                }
                result.add(OpenAIMessage("assistant", contentToText(am.content), rc, "", tcs))
            case tm: ToolResultMessage =>
                result.add(OpenAIMessage("tool", contentToText(tm.content), Option<String>.None,
                    tm.toolCallId, ArrayList<JsonValue>()))
            case cm: CompactionMessage =>
                result.add(OpenAIMessage("user", "[Summary: " + cm.summary + "]", Option<String>.None, "", ArrayList<JsonValue>()))
            case _ => ()
        }
    }
    result
}

func contentToText(cl: ContentList): String {
    let sb = StringBuilder()
    for (b in cl.blocks()) {
        match (b) {
            case ContentBlock.TextBlock(t) => sb.append(t)
            case _ => ()
        }
    }
    sb.toString()
}

func stopReasonFromStr(s: String): StopReason {
    match (s) {
        case "stop" => StopReason.EndTurn
        case "tool_calls" => StopReason.ToolUse
        case "length" => StopReason.Length
        case _ => StopReason.EndTurn
    }
}

func readAll(input: InputStream): String {
    let buf = Array<Byte>(4096, repeat: 0)
    let all = ArrayList<Byte>()
    while (true) {
        let n: Int64
        try { n = input.read(buf) } catch (_) { break }
        if (n <= 0) { break }
        for (i in 0..n) { all.add(buf[Int64(i)]) }
    }
    let raw = Array<Byte>(all.size, repeat: 0)
    for (i in 0..all.size) { raw[i] = all[i] }
    String.fromUtf8(raw)
}

func applyExtraHeaders(b: HttpRequestBuilder, headers: ArrayList<String>): Unit {
    for (h in headers) {
        match (h.indexOf(":")) {
            case Some(i) =>
                let hName = h[0..i].trimAscii()
                let hVal = h[i + 1..].trimAscii()
                if (hName != "") { b.header(hName, hVal) }
            case None => ()
        }
    }
}

func mergeToolCalls(acc: ArrayList<JsonValue>, incoming: ArrayList<JsonValue>): Unit {
    for (tc in incoming) {
        let idx: Int64 = match (tc["index"]) {
            case Some(JsonValue.Number(n)) => Int64(n)
            case _ => -1
        }
        if (idx < 0) { continue }
        var found = false
        for (j in 0..acc.size) {
            let existing = acc[Int64(j)]
            let eIdx: Int64 = match (existing["index"]) {
                case Some(JsonValue.Number(n)) => Int64(n)
                case _ => -1
            }
            if (eIdx == idx) {
                found = true
                match (existing) {
                    case JsonValue.Map(exMap) =>
                        match (tc) {
                            case JsonValue.Map(inMap) =>
                                let merged = HashMap<String, JsonValue>()
                                for ((k, v) in exMap) { merged.add(k, v) }
                                for ((k, v) in inMap) {
                                    match (merged.get(k)) {
                                        case Some(JsonValue.Map(oldM)) =>
                                            match (v) {
                                                case JsonValue.Map(newM) =>
                                                    let mergedSub = HashMap<String, JsonValue>()
                                                    for ((sk, sv) in oldM) { mergedSub.add(sk, sv) }
                                                    for ((sk, sv) in newM) {
                                                        // Special: concatenate function.arguments
                                                        if (k == "function" && sk == "arguments") {
                                                            let oldArgs = match (oldM.get("arguments")) {
                                                                case Some(JsonValue.String(s)) => s; case _ => ""
                                                            }
                                                            let newArgs = match (sv) {
                                                                case JsonValue.String(s) => s; case _ => ""
                                                            }
                                                            mergedSub.add(sk, JsonValue.String(oldArgs + newArgs))
                                                        } else {
                                                            mergedSub.add(sk, sv)
                                                        }
                                                    }
                                                    merged.add(k, JsonValue.Map(mergedSub))
                                                case _ => merged.add(k, v)
                                            }
                                        case _ => merged.add(k, v)
                                    }
                                }
                                acc[Int64(j)] = JsonValue.Map(merged)
                            case _ => ()
                        }
                    case _ => ()
                }
                break
            }
        }
        if (!found) { acc.add(tc) }
    }
}

func buildContent(text: String, toolCalls: ArrayList<JsonValue>): ContentList {
    let blocks = ArrayList<ContentBlock>()
    blocks.add(ContentBlock.TextBlock(text))
    for (tc in toolCalls) {
        let id = match (tc["id"]) { case Some(JsonValue.String(s)) => s; case _ => "" }
        let fnName = match (tc["function"]) {
            case Some(JsonValue.Map(m)) => match (m.get("name")) { case Some(JsonValue.String(s)) => s; case _ => "" }
            case _ => ""
        }
        let fnArgs = match (tc["function"]) {
            case Some(JsonValue.Map(m)) => match (m.get("arguments")) { case Some(v) => v; case _ => JsonValue.Null }
            case _ => JsonValue.Null
        }
        // arguments from the API is a JSON string, parse it
        let parsedArgs = match (fnArgs) {
            case JsonValue.String(s) =>
                try { JsonValue.parse(s) } catch (_) { fnArgs }
            case _ => fnArgs
        }
        if (id != "" && fnName != "") {
            blocks.add(ContentBlock.ToolCall(ToolCallBlock(id, fnName, parsedArgs)))
        }
    }
    ContentList(blocks)
}
