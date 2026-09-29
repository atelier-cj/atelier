package atelier.ptc

import jsonvalue.*
import std.collection.*
import ystyle::xisp.types.*
import ystyle::xisp.core.eval.INTERRUPTED_MESSAGE

/**
 * `JsonValue` 与 xisp 的 `LispValue` 之间的双向转换。
 *
 * 对应关系（由实测锁定）：
 * - `null` ↔ `Nil`
 * - `boolean` ↔ `Boolean`
 * - `number` ↔ `Int`（整数值）/ `Float`
 * - `string` ↔ `Str`
 * - `array` ↔ 列表（Cons 链）
 * - `object` ↔ `HashMap`（脚本里的 `{...}` 字面量直接就是 `LispValue.HashMap`）
 *
 * 转换函数/闭包/错误值等运行期对象没有 JSON 对应物，返回 `None` 由调用方处理。
 */
public class JsonBridge {

    /**
     * JSON → Lisp。
     */
    public static func toLisp(value: JsonValue): LispValue {
        match (value) {
            case JsonValue.Null => LispValue.Nil
            case JsonValue.Boolean(b) => LispValue.Boolean(b)
            case JsonValue.Number(n) => numberToLisp(n)
            case JsonValue.String(s) => LispValue.Str(s)
            case JsonValue.Array(items) => arrayToLisp(items)
            case JsonValue.Map(m) =>
                let bindings = HashMap<String, LispValue>()
                for ((k, v) in m) {
                    bindings.add(k, toLisp(v))
                }
                LispValue.HashMap(bindings)
        }
    }

    /**
     * 数组 → 列表。
     *
     * 迭代构造而非用 `types.list()`：后者按元素递归，长数组会耗尽栈
     * （实测 10 万元素即 OutOfMemoryError）。
     */
    private static func arrayToLisp(items: ArrayList<JsonValue>): LispValue {
        var result: LispValue = LispValue.Nil
        var i = items.size
        while (i > 0) {
            i = i - 1
            result = consValue(toLisp(items[i]), result)
        }
        result
    }

    /**
     * 数字 → Lisp。
     *
     * `JsonValue` 只有 `Number(Float64)`，但工具参数里的整数很常见
     * （`{:limit 10}`），整数值一律还原为 `Int`，避免脚本拿到 `10.0`
     * 后参与运算产生浮点结果。
     */
    private static func numberToLisp(n: Float64): LispValue {
        // Int64 可精确表示的范围；超出或非有限值保持浮点
        if (n >= -9223372036854775808.0 && n <= 9223372036854775807.0) {
            let asInt = Int64(n)
            if (Float64(asInt) == n) {
                return LispValue.Int(asInt)
            }
        }
        LispValue.Float(n)
    }

    /**
     * Lisp → JSON。无法表达为 JSON 的值返回 `None`。
     *
     * 严格而非宽容：把闭包悄悄转成字符串之类会掩盖模型的错误，
     * 调用方应当把 `None` 当作「完成值不可序列化」上报。
     */
    public static func toJson(value: LispValue): Option<JsonValue> {
        match (value) {
            case LispValue.Nil => Some(JsonValue.Null)
            case LispValue.Boolean(b) => Some(JsonValue.Boolean(b))
            case LispValue.Int(i) => Some(JsonValue.Number(Float64(i)))
            case LispValue.Float(f) => Some(JsonValue.Number(f))
            case LispValue.Str(s) => Some(JsonValue.String(s))
            // 符号按标识符文本序列化：脚本用 'done 之类的字面量作完成值是常见写法
            case LispValue.Symbol(s) => Some(JsonValue.String(s))
            case LispValue.Cons(_) => listToJson(value)
            case LispValue.HashMap(m) =>
                let out = HashMap<String, JsonValue>()
                for ((k, v) in m) {
                    match (toJson(v)) {
                        case Some(j) => out.add(k, j)
                        case None => return None
                    }
                }
                Some(JsonValue.Map(out))
            // 过程、闭包、原生函数、错误值：没有 JSON 对应物
            case _ => None
        }
    }

    /**
     * Cons 链 → JSON 数组。非真列表（点对）返回 `None`。
     */
    private static func listToJson(value: LispValue): Option<JsonValue> {
        let items = ArrayList<JsonValue>()
        var current = value
        while (let Cons(cell) <- current) {
            match (toJson(cell.car)) {
                case Some(j) => items.add(j)
                case None => return None
            }
            current = cell.cdr
        }
        match (current) {
            case LispValue.Nil => Some(JsonValue.Array(items))
            // 点对不是列表，无法表示成 JSON 数组
            case _ => None
        }
    }

    /**
     * 取出 xisp 错误值的消息；非错误值返回 `None`。
     *
     * 求值结果里的错误以值表达（`LispValue.Error`），宿主据此把它转成
     * `PtcRunFailure`。
     */
    public static func errorMessage(value: LispValue): Option<String> {
        match (value) {
            case LispValue.Error(e) => Some(e.message)
            case _ => None
        }
    }

    /**
     * 该错误值是否由求值中断产生（外层取消或超时）。
     *
     * 中断与脚本自身的运行时错误都是 `RuntimeError` 值，靠固定消息区分。
     */
    public static func isInterrupt(value: LispValue): Bool {
        match (value) {
            case LispValue.Error(e) => e.message == INTERRUPTED_MESSAGE
            case _ => false
        }
    }

    /**
     * 取出对象里的字符串字段；缺失或类型不符返回 `None`。
     *
     * 工具参数是 JSON 对象，读取其中的字符串字段（如 `code` / `description`）
     * 在运行期与呈现层都要用，因此放在这里而不是各自的调用点。
     */
    public static func stringField(value: JsonValue, name: String): Option<String> {
        match (value) {
            case JsonValue.Map(m) =>
                match (m.get(name)) {
                    case Some(JsonValue.String(s)) => Some(s)
                    case _ => None
                }
            case _ => None
        }
    }

    /** 渲染嵌套深度上限：完成值可能来自工具，结构不可控。 */
    private static let MAX_RENDER_DEPTH: Int64 = 32

    /**
     * 把 JSON 值渲染成单行文本，供工具结果卡片展示。
     *
     * 自带深度上限：完成值的结构来自模型或工具，不受本仓控制，
     * 未加限制的递归渲染会被深层嵌套打爆栈。
     */
    public static func render(value: JsonValue): String {
        renderAt(value, 0)
    }

    private static func renderAt(value: JsonValue, depth: Int64): String {
        if (depth > MAX_RENDER_DEPTH) {
            return "…"
        }
        match (value) {
            case JsonValue.Null => "null"
            case JsonValue.Boolean(b) => if (b) { "true" } else { "false" }
            case JsonValue.Number(n) => renderNumber(n)
            case JsonValue.String(s) => "\"${escape(s)}\""
            case JsonValue.Array(items) =>
                let parts = ArrayList<String>()
                for (item in items) {
                    parts.add(renderAt(item, depth + 1))
                }
                "[${String.join(parts.toArray(), delimiter: ", ")}]"
            case JsonValue.Map(m) =>
                let parts = ArrayList<String>()
                for ((k, v) in m) {
                    parts.add("\"${escape(k)}\": ${renderAt(v, depth + 1)}")
                }
                "{${String.join(parts.toArray(), delimiter: ", ")}}"
        }
    }

    /** 整数值不带小数尾巴：脚本返回 3 时展示 3 而不是 3.0。 */
    private static func renderNumber(n: Float64): String {
        if (n >= -9223372036854775808.0 && n <= 9223372036854775807.0) {
            let asInt = Int64(n)
            if (Float64(asInt) == n) {
                return asInt.toString()
            }
        }
        n.toString()
    }

    /** 最小转义：引号、反斜杠与控制字符。 */
    private static func escape(text: String): String {
        let sb = StringBuilder()
        for (r in text.toRuneArray()) {
            match (r) {
                case r'"' => sb.append("\\\"")
                case r'\\' => sb.append("\\\\")
                case r'\n' => sb.append("\\n")
                case r'\r' => sb.append("\\r")
                case r'\t' => sb.append("\\t")
                case _ => sb.append(r.toString())
            }
        }
        sb.toString()
    }
}
