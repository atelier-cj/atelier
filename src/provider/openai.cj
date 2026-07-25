package atelier.provider

import stdx.net.http.*
import stdx.net.tls.*
import stdx.encoding.url.*
import std.io.InputStream
import std.collection.*
import atelier.message.*
import atelier.event.EventStream
import atelier.util.{toJsonString, fromJsonString}

public class OpenAIProvider <: Provider {
    private let provName: String
    private let baseURL: String
    private let apiKey: String
    private let httpClient: Client

    public init(name: String, baseURL: String, apiKey: String) {
        this.provName = name
        this.baseURL = baseURL.trimEnd('/')
        this.apiKey = apiKey
        let b = ClientBuilder()
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
        let httpReq = HttpRequestBuilder()
            .url(this.baseURL + "/chat/completions")
            .header("Content-Type", "application/json")
            .header("Authorization", "Bearer " + this.apiKey)
            .body(bodyJson)
            .post()
            .build()
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
            doStreamRequest(this.httpClient, this.baseURL, this.apiKey, bodyJson, stream)
        }
        stream
    }
}

func buildRequest(req: ChatRequest, stream: Bool): OpenAIRequest {
    OpenAIRequest(req.model, messagesToOpenAI(req.messages), stream,
        req.temperature, req.maxTokens, req.reasoningEffort)
}

func doStreamRequest(client: Client, baseURL: String, apiKey: String,
    bodyJson: String, stream: EventStream<ChatDelta, AssistantMessage>): Unit {
    try {
        let httpReq = HttpRequestBuilder()
            .url(baseURL + "/chat/completions")
            .header("Content-Type", "application/json")
            .header("Authorization", "Bearer " + apiKey)
            .body(bodyJson)
            .post()
            .build()
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
                                streamDone = true
                                Some(stopReasonFromStr(s))
                            case None => Option<StopReason>.None
                        }
                        stream.emit(ChatDelta(sc.delta.content, sc.delta.reasoningContent, sReason))
                    }
                } else {
                    lineBuf.add(b)
                }
            }
        }
        let finalText = contentBuilder.toString()
        let reasoningText = reasoningBuilder.toString()
        let assistantMsg = AssistantMessage(
            ContentList.ofText(finalText), "", "",
            StopReason.EndTurn, TokenUsage(0, 0), 0,
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
                result.add(OpenAIMessage("user", contentToText(um.content), Option<String>.None))
            case am: AssistantMessage =>
                let rc: Option<String> = if (am.reasoningContent != "") { Some(am.reasoningContent) } else { Option<String>.None }
                result.add(OpenAIMessage("assistant", contentToText(am.content), rc))
            case tm: ToolResultMessage =>
                result.add(OpenAIMessage("tool", contentToText(tm.content), Option<String>.None))
            case cm: CompactionMessage =>
                result.add(OpenAIMessage("user", "[Summary: " + cm.summary + "]", Option<String>.None))
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
