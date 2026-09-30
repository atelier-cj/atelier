package atelier.interaction

import std.collection.*
import jsonvalue.*
import atelier.util.{toJsonString, fromJsonString}

// 答复的持久化编码：把 UserAnswer 装进消息的元数据通道（HashMap<String, String>）。
//
// 为什么走元数据而不是新加一种 Message 变体：Message 是 llm_api 里的 sealed 接口，
// 新增变体会让四个仓的穷举匹配同时要改（几十处），而元数据通道本就是为宿主业务数据准备的、
// 随会话持久化 roundtrip。行为一致、成本低、可逆（将来要升一等公民，把这里换成新变体即可）。
//
// 约定（键名即契约）：
//   ask.id / ask.status / ask.selected（逗号分隔）/ ask.text / ask.values（JSON）/ ask.editedArgs（JSON）
public let ASK_ID = "ask.id"
public let ASK_STATUS = "ask.status"
public let ASK_SELECTED = "ask.selected"
public let ASK_TEXT = "ask.text"
public let ASK_VALUES = "ask.values"
public let ASK_EDITED_ARGS = "ask.editedArgs"

// 这条消息是否携带答复
public func isAnswerMetadata(m: HashMap<String, String>): Bool {
    match (m.get(ASK_ID)) {
        case Some(v) => v != ""
        case None => false
    }
}


// 解析前的形状检查：截断的 JSON（如 `{not json`）会让 JsonValue.fromJson 无限递归到 OOM
// （实测，不是异常——try/catch 兜不住），所以必须**先判断再解析**。
// 自己编码出来的值一定是完整对象，因此这里只放行"看起来完整"的输入。
func looksLikeJsonComposite(s: String): Bool {
    var text = s
    while (text.startsWith(" ") || text.startsWith("\n") || text.startsWith("\t")) {
        text = text[1..text.size]
    }
    if (text.startsWith("{")) { return text.endsWith("}") }
    if (text.startsWith("[")) { return text.endsWith("]") }
    // 标量（数字/字符串/布尔/null）长度有限，交给解析器
    text.size <= 64
}

public func encodeAnswer(a: UserAnswer): HashMap<String, String> {
    let out = HashMap<String, String>()
    out[ASK_ID] = a.requestId
    out[ASK_STATUS] = a.statusName()
    if (a.selected.size > 0) {
        let sb = StringBuilder()
        for (i in 0..a.selected.size) {
            if (i > 0) { sb.append(",") }
            sb.append(a.selected[Int64(i)])
        }
        out[ASK_SELECTED] = sb.toString()
    }
    if (a.text != "") { out[ASK_TEXT] = a.text }
    if (a.values.size > 0) {
        out[ASK_VALUES] = toJsonString(JsonValue.Map(a.values))
    }
    match (a.editedArgs) {
        case Some(v) => out[ASK_EDITED_ARGS] = toJsonString(v)
        case None => ()
    }
    out
}

// 解码失败（键坏/JSON 坏）返回 None：宁可当作"没有答复"再问一次，也不要拿半个答复去执行
public func decodeAnswer(m: HashMap<String, String>): Option<UserAnswer> {
    let id = match (m.get(ASK_ID)) {
        case Some(v) => v
        case None => return None
    }
    if (id == "") { return None }
    let statusRaw = match (m.get(ASK_STATUS)) {
        case Some(v) => v
        case None => "answered"
    }
    let status = match (statusRaw) {
        case "pending" => UserAnswerStatus.Pending
        case "cancelled" => UserAnswerStatus.Cancelled
        case "timed_out" => UserAnswerStatus.TimedOut
        case _ => UserAnswerStatus.Answered
    }
    let selected = ArrayList<String>()
    match (m.get(ASK_SELECTED)) {
        case Some(v) => for (part in v.split(",")) {
            if (part != "") { selected.add(part) }
        }
        case None => ()
    }
    let text = match (m.get(ASK_TEXT)) {
        case Some(v) => v
        case None => ""
    }
    let values = HashMap<String, JsonValue>()
    match (m.get(ASK_VALUES)) {
        case Some(raw) =>
            if (!looksLikeJsonComposite(raw)) { return None }
            try {
                match (fromJsonString<JsonValue>(raw)) {
                    case JsonValue.Map(vals) =>
                        for (k in vals.keys()) {
                            match (vals.get(k)) {
                                case Some(v) => values[k] = v
                                case None => ()
                            }
                        }
                    case _ => ()
                }
            } catch (_) {
                return None
            }
        case None => ()
    }
    var edited: Option<JsonValue> = None
    match (m.get(ASK_EDITED_ARGS)) {
        case Some(raw) =>
            if (!looksLikeJsonComposite(raw)) { return None }
            try {
                edited = Some(fromJsonString<JsonValue>(raw))
            } catch (_) {
                return None
            }
        case None => ()
    }
    Some(UserAnswer(id, status, selected: selected, text: text, values: values, editedArgs: edited))
}
