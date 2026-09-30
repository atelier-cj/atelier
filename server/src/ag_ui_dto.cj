package server

import std.collection.*
import stdx.encoding.json.stream.*
import jsonvalue.JsonValue

// AG-UI 入站 DTO（RunAgentInput 及其子结构），解析一律走 json.stream。
//
// 容错原则（协议除 threadId/runId 外字段都可省，各家客户端实现也有差异）：
// · 未知字段 skip、缺失字段取默认值；
// · message.content 允许字符串，也允许 [{type:"text",text}] 形态的分片数组（取其中的文本）；
// · 工具参数原样保留为 JsonValue，不做形状假设。
//
// ⚠️ 嵌套复合值一律**手写 token 遍历**，不用 `readValue<T>()`/`readValue<ArrayList<T>>()`：
// stdx JsonReader 的嵌套 afterRead 会消费字段间逗号并置 peeked=NAME，外层再 peek 时 guard
// 不匹配 → 抛 IllegalStateException: Commas are required to separate values…。
// 也就是说「复合值后面还有成员」就中招（`toolCalls[].function` 后面跟别的字段正是这种）。
// 标量字段用 readValue 没问题，复合字段直接用 T.fromJson(r) / JsonValue.fromJson(r) 递归。

public class AgUiFunctionDTO <: JsonDeserializable<AgUiFunctionDTO> {
    public let name: String
    public let arguments: String

    public init(name: String, arguments: String) {
        this.name = name; this.arguments = arguments
    }

    public static func fromJson(r: JsonReader): AgUiFunctionDTO {
        var name = ""
        var arguments = ""
        r.startObject()
        while (r.peek() != JsonToken.EndObject) {
            match (r.readName()) {
                case "name" => name = r.readValue<String>()
                case "arguments" => arguments = r.readValue<String>()
                case _ => r.skip()
            }
        }
        r.endObject()
        AgUiFunctionDTO(name, arguments)
    }
}

public class AgUiToolCallDTO <: JsonDeserializable<AgUiToolCallDTO> {
    public let id: String
    public let function: AgUiFunctionDTO

    public init(id: String, function: AgUiFunctionDTO) {
        this.id = id; this.function = function
    }

    public static func fromJson(r: JsonReader): AgUiToolCallDTO {
        var id = ""
        var fn = AgUiFunctionDTO("", "")
        r.startObject()
        while (r.peek() != JsonToken.EndObject) {
            match (r.readName()) {
                case "id" => id = r.readValue<String>()
                case "function" => fn = readAgUiFunction(r)
                case _ => r.skip()
            }
        }
        r.endObject()
        AgUiToolCallDTO(id, fn)
    }
}

// function 对象内联解析（见文件头：复合值不能走 readValue）
func readAgUiFunction(r: JsonReader): AgUiFunctionDTO {
    var name = ""
    var arguments = ""
    r.startObject()
    while (r.peek() != JsonToken.EndObject) {
        match (r.readName()) {
            case "name" => name = r.readValue<String>()
            case "arguments" => arguments = r.readValue<String>()
            case _ => r.skip()
        }
    }
    r.endObject()
    AgUiFunctionDTO(name, arguments)
}

// 分片数组形态的 content（[{type:"text",text:"..."}, ...]）只取文本分片
func readAgUiContentParts(r: JsonReader): String {
    let sb = StringBuilder()
    r.startArray()
    while (r.peek() != JsonToken.EndArray) {
        r.startObject()
        while (r.peek() != JsonToken.EndObject) {
            match (r.readName()) {
                case "text" => sb.append(r.readValue<String>())
                case _ => r.skip()
            }
        }
        r.endObject()
    }
    r.endArray()
    sb.toString()
}

public class AgUiMessageDTO <: JsonDeserializable<AgUiMessageDTO> {
    public let id: String
    public let role: String
    public let content: String
    public let toolCallId: String
    public let toolCalls: ArrayList<AgUiToolCallDTO>

    public init(id: String, role: String, content: String, toolCallId: String,
        toolCalls: ArrayList<AgUiToolCallDTO>) {
        this.id = id; this.role = role; this.content = content
        this.toolCallId = toolCallId; this.toolCalls = toolCalls
    }

    public static func fromJson(r: JsonReader): AgUiMessageDTO {
        var id = ""
        var role = ""
        var content = ""
        var toolCallId = ""
        var toolCalls = ArrayList<AgUiToolCallDTO>()
        r.startObject()
        while (r.peek() != JsonToken.EndObject) {
            match (r.readName()) {
                case "id" => id = r.readValue<String>()
                case "role" => role = r.readValue<String>()
                case "content" =>
                    if (r.peek() == JsonToken.BeginArray) {
                        content = readAgUiContentParts(r)
                    } else if (r.peek() == JsonToken.JsonNull) {
                        r.skip()
                    } else {
                        content = r.readValue<String>()
                    }
                case "toolCallId" => toolCallId = r.readValue<String>()
                case "toolCalls" =>
                    r.startArray()
                    while (r.peek() != JsonToken.EndArray) {
                        toolCalls.add(AgUiToolCallDTO.fromJson(r))
                    }
                    r.endArray()
                case _ => r.skip()
            }
        }
        r.endObject()
        AgUiMessageDTO(id, role, content, toolCallId, toolCalls)
    }
}

public class AgUiToolDTO <: JsonDeserializable<AgUiToolDTO> {
    public let name: String
    public let description: String
    public let parameters: Option<JsonValue>

    public init(name: String, description: String, parameters: Option<JsonValue>) {
        this.name = name; this.description = description; this.parameters = parameters
    }

    public static func fromJson(r: JsonReader): AgUiToolDTO {
        var name = ""
        var description = ""
        var parameters: Option<JsonValue> = None
        r.startObject()
        while (r.peek() != JsonToken.EndObject) {
            match (r.readName()) {
                case "name" => name = r.readValue<String>()
                case "description" => description = r.readValue<String>()
                case "parameters" => parameters = Some(JsonValue.fromJson(r))
                case _ => r.skip()
            }
        }
        r.endObject()
        AgUiToolDTO(name, description, parameters)
    }
}

public class AgUiContextDTO <: JsonDeserializable<AgUiContextDTO> {
    public let description: String
    public let value: String

    public init(description: String, value: String) {
        this.description = description; this.value = value
    }

    public static func fromJson(r: JsonReader): AgUiContextDTO {
        var description = ""
        var value = ""
        r.startObject()
        while (r.peek() != JsonToken.EndObject) {
            match (r.readName()) {
                case "description" => description = r.readValue<String>()
                case "value" => value = r.readValue<String>()
                case _ => r.skip()
            }
        }
        r.endObject()
        AgUiContextDTO(description, value)
    }
}

public class RunAgentInput <: JsonDeserializable<RunAgentInput> {
    public let threadId: String
    public let runId: String
    public let state: Option<JsonValue>
    public let messages: ArrayList<AgUiMessageDTO>
    public let tools: ArrayList<AgUiToolDTO>
    public let context: ArrayList<AgUiContextDTO>
    public let forwardedProps: Option<JsonValue>

    public init(threadId: String, runId: String, state: Option<JsonValue>,
        messages: ArrayList<AgUiMessageDTO>, tools: ArrayList<AgUiToolDTO>,
        context: ArrayList<AgUiContextDTO>, forwardedProps: Option<JsonValue>) {
        this.threadId = threadId; this.runId = runId; this.state = state
        this.messages = messages; this.tools = tools
        this.context = context; this.forwardedProps = forwardedProps
    }

    public static func fromJson(r: JsonReader): RunAgentInput {
        var threadId = ""
        var runId = ""
        var state: Option<JsonValue> = None
        var messages = ArrayList<AgUiMessageDTO>()
        var tools = ArrayList<AgUiToolDTO>()
        var context = ArrayList<AgUiContextDTO>()
        var forwarded: Option<JsonValue> = None
        r.startObject()
        while (r.peek() != JsonToken.EndObject) {
            match (r.readName()) {
                case "threadId" => threadId = r.readValue<String>()
                case "runId" => runId = r.readValue<String>()
                case "state" => state = Some(JsonValue.fromJson(r))
                case "messages" =>
                    r.startArray()
                    while (r.peek() != JsonToken.EndArray) {
                        messages.add(AgUiMessageDTO.fromJson(r))
                    }
                    r.endArray()
                case "tools" =>
                    r.startArray()
                    while (r.peek() != JsonToken.EndArray) {
                        tools.add(AgUiToolDTO.fromJson(r))
                    }
                    r.endArray()
                case "context" =>
                    r.startArray()
                    while (r.peek() != JsonToken.EndArray) {
                        context.add(AgUiContextDTO.fromJson(r))
                    }
                    r.endArray()
                case "forwardedProps" => forwarded = Some(JsonValue.fromJson(r))
                case _ => r.skip()
            }
        }
        r.endObject()
        RunAgentInput(threadId, runId, state, messages, tools, context, forwarded)
    }

    // forwardedProps.agent：客户端指定本次 run 用哪个 agent（缺省时由服务端挑默认 agent）
    public func agentName(): Option<String> {
        match (this.forwardedProps) {
            case Some(props) =>
                match (props["agent"]) {
                    case Some(JsonValue.String(s)) => Some(s)
                    case _ => None
                }
            case None => None
        }
    }

    // forwardedProps.systemPrompt：本次 run 的额外系统指令（与 system/developer 角色消息同义）
    public func systemPromptOverride(): Option<String> {
        match (this.forwardedProps) {
            case Some(props) =>
                match (props["systemPrompt"]) {
                    case Some(JsonValue.String(s)) => Some(s)
                    case _ => None
                }
            case None => None
        }
    }
}

// /ag-ui/input 的回传体：kind = user_input（askUser 的回答）| tool_result（客户端工具结果）
public class AgUiInputDTO <: JsonDeserializable<AgUiInputDTO> {
    public let runId: String
    public let kind: String
    public let text: String
    public let toolCallId: String
    public let result: String
    public let isError: Bool

    public init(runId: String, kind: String, text: String, toolCallId: String,
        result: String, isError: Bool) {
        this.runId = runId; this.kind = kind; this.text = text
        this.toolCallId = toolCallId; this.result = result; this.isError = isError
    }

    public static func fromJson(r: JsonReader): AgUiInputDTO {
        var runId = ""
        var kind = ""
        var text = ""
        var toolCallId = ""
        var result = ""
        var isError = false
        r.startObject()
        while (r.peek() != JsonToken.EndObject) {
            match (r.readName()) {
                case "runId" => runId = r.readValue<String>()
                case "kind" => kind = r.readValue<String>()
                case "text" => text = r.readValue<String>()
                case "toolCallId" => toolCallId = r.readValue<String>()
                case "result" => result = r.readValue<String>()
                case "isError" => isError = r.readValue<Bool>()
                case _ => r.skip()
            }
        }
        r.endObject()
        AgUiInputDTO(runId, kind, text, toolCallId, result, isError)
    }
}
