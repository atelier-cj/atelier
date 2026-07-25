package atelier.provider

import stdx.encoding.json.stream.*
import stdx.net.http.*
import std.io.{ByteBuffer, InputStream}
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
        this.httpClient = ClientBuilder()
            .readTimeout(120 * Duration.second)
            .build()
    }

    public func name(): String { this.provName }

    public func chat(req: ChatRequest): ChatResponse {
        let oaiReq = OpenAIRequest(req.model, messagesToOpenAI(req.messages), false, req.temperature, req.maxTokens)
        let bodyJson = toJsonString(oaiReq)
        let httpReq = HttpRequestBuilder()
            .url(this.baseURL + "/chat/completions")
            .header("content-type", "application/json")
            .header("authorization", "Bearer " + this.apiKey)
            .body(bodyJson)
            .post()
            .build()
        let resp = this.httpClient.send(httpReq)
        if (resp.status != 200) {
            throw Exception("OpenAI API error: " + resp.status.toString() + "\n" + readAll(resp.body))
        }
        let json = readAll(resp.body)
        let oaiResp = fromJsonString<OpenAIResponse>(json)
        if (oaiResp.choices.size == 0) { throw Exception("No choices in response") }
        let choice = oaiResp.choices[0]
        ChatResponse(AssistantMessage(
            ContentList.ofText(choice.message.content), "", "", stopReasonFromStr(choice.finishReason),
            TokenUsage(oaiResp.usage.promptTokens, oaiResp.usage.completionTokens), 0))
    }

    public func chatStreaming(req: ChatRequest): EventStream<ChatDelta, AssistantMessage> {
        let stream = EventStream<ChatDelta, AssistantMessage>()
        let oaiReq = OpenAIRequest(req.model, messagesToOpenAI(req.messages), true, req.temperature, req.maxTokens)
        let bodyJson = toJsonString(oaiReq)
        spawn {
            doStreamRequest(this.httpClient, this.baseURL, this.apiKey, bodyJson, stream)
        }
        stream
    }
}

func doStreamRequest(client: Client, baseURL: String, apiKey: String, bodyJson: String, stream: EventStream<ChatDelta, AssistantMessage>): Unit {
    try {
        let httpReq = HttpRequestBuilder()
            .url(baseURL + "/chat/completions")
            .header("content-type", "application/json")
            .header("authorization", "Bearer " + apiKey)
            .body(bodyJson)
            .post()
            .build()
        let resp = client.send(httpReq)
        if (resp.status != 200) {
            stream.setError(Exception("OpenAI API error: " + resp.status.toString() + " " + readAll(resp.body)))
            return
        }
        let body = resp.body
        let contentBuilder = StringBuilder()

        for (lineStr in readSSELines(body)) {
            if (!lineStr.startsWith("data: ")) { continue }
            let data = lineStr[6..]
            if (data == "[DONE]") { break }
            let chunk = fromJsonString<OpenAIStreamChunk>(data)
            if (chunk.choices.size == 0) { continue }
            let delta = chunk.choices[0].delta
            contentBuilder.append(delta.content)
            let finReason = chunk.choices[0].finishReason
            let sReason: Option<StopReason> = match (finReason) {
                case Some(s) => Some(stopReasonFromStr(s))
                case None => None
            }
            stream.emit(ChatDelta(delta.content, sReason))
            match (sReason) {
                case Some(_) => break
                case None => ()
            }
        }

        let finalText = contentBuilder.toString()
        let assistantMsg = AssistantMessage(
            ContentList.ofText(finalText), "", "", StopReason.EndTurn,
            TokenUsage(0, 0), 0)
        stream.setResult(assistantMsg)
    } catch (e: Exception) {
        stream.setError(e)
    }
}

func messagesToOpenAI(msgs: ArrayList<Message>): ArrayList<OpenAIMessage> {
    let result = ArrayList<OpenAIMessage>()
    for (m in msgs) {
        match (m) {
            case um: UserMessage => result.add(OpenAIMessage("user", contentToText(um.content)))
            case am: AssistantMessage => result.add(OpenAIMessage("assistant", contentToText(am.content)))
            case tm: ToolResultMessage => result.add(OpenAIMessage("tool", contentToText(tm.content)))
            case cm: CompactionMessage => result.add(OpenAIMessage("user", "[Summary: " + cm.summary + "]"))
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

func readSSELines(input: InputStream): ArrayList<String> {
    let result = ArrayList<String>()
    let buf = Array<Byte>(1, repeat: 0)
    let lineBuf = ArrayList<Byte>()
    while (true) {
        let n: Int64
        try { n = input.read(buf) } catch (_) { break }
        if (n <= 0) { break }
        lineBuf.add(buf[0])
        if (buf[0] == 10) {
            let raw = Array<Byte>(lineBuf.size, repeat: 0)
            for (i in 0..lineBuf.size) { raw[i] = lineBuf[i] }
            result.add(String.fromUtf8(raw))
            lineBuf.clear()
        }
    }
    if (lineBuf.size > 0) {
        let raw = Array<Byte>(lineBuf.size, repeat: 0)
        for (i in 0..lineBuf.size) { raw[i] = lineBuf[i] }
        result.add(String.fromUtf8(raw))
    }
    result
}
