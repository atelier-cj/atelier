package atelier.ptc

import jsonvalue.*
import std.collection.*
import atelier.tool.*

/**
 * 把可见工具集渲染成 `tools:sdk` 提示词段。
 *
 * 这是 native 模式 JSON Schema 的另一种投影，不是第二份工具定义：两者都由
 * 同一个可见工具集生成，因此模型在两种模式下看到的可用能力始终一致。
 *
 * 输出字节稳定（工具按名排序、对象键排序），以便提示词前缀缓存。
 */
public class PtcSdkRenderer {

    /** 抽取成命名类型的重复次数阈值。 */
    private static let DEFTYPE_THRESHOLD: Int64 = 2

    /** 渲染整个 SDK 段；没有可见工具时返回空串（调用方据此跳过该段）。 */
    public static func render(tools: ArrayList<Tool>): String {
        if (tools.size == 0) {
            return ""
        }
        let sorted = sortByName(tools)

        // 1) 统计重复的对象结构：同一子结构出现多次时抽成 deftype，
        //    这是 JSON Schema 缺的能力——$ref/$defs 常在透传层被丢弃，
        //    而 MCP 工具的 schema 完全不可控。
        let order = ArrayList<String>()
        let counts = HashMap<String, Int64>()
        for (tool in sorted) {
            collectObjects(tool.schema(), order, counts)
        }
        let names = HashMap<String, String>()
        var assigned: Int64 = 0
        for (key in order) {
            match (counts.get(key)) {
                case Some(n) =>
                    if (n >= DEFTYPE_THRESHOLD) {
                        assigned = assigned + 1
                        names.add(key, "T${assigned}")
                    }
                case None => ()
            }
        }

        // 2) 组装文本
        let sb = StringBuilder()
        sb.append(INSTRUCTIONS)

        if (names.size > 0) {
            sb.append("\n\n共享类型：\n")
            for (key in order) {
                match (names.get(key)) {
                    case Some(name) =>
                        sb.append(";; (deftype ${name} ${key})\n")
                    case None => ()
                }
            }
        }

        sb.append("\n\n可用工具：\n")
        for (tool in sorted) {
            sb.append(renderSignature(tool, names))
            sb.append("\n")
        }

        sb.append("\n")
        sb.append(EXAMPLE)
        sb.toString()
    }

    /** 工具按名排序，保证输出字节稳定。 */
    private static func sortByName(tools: ArrayList<Tool>): ArrayList<Tool> {
        let sorted = ArrayList<Tool>(tools)
        // 冒泡排序：工具数量很小（几十个量级），且避免引入排序依赖
        let n = sorted.size
        var i: Int64 = 0
        while (i < n) {
            var j: Int64 = 0
            while (j + 1 < n - i) {
                if (sorted[j].name() > sorted[j + 1].name()) {
                    let tmp = sorted[j]
                    sorted[j] = sorted[j + 1]
                    sorted[j + 1] = tmp
                }
                j = j + 1
            }
            i = i + 1
        }
        sorted
    }

    // ==================== 重复结构抽取 ====================

    /**
     * 递归收集所有对象结构，按首次出现顺序记录，并统计出现次数。
     *
     * 只把「有 properties 的对象」纳入候选：其余标量结构抽出来没有价值。
     */
    private static func collectObjects(
        node: JsonValue,
        order: ArrayList<String>,
        counts: HashMap<String, Int64>
    ): Unit {
        match (node) {
            case JsonValue.Map(m) =>
                if (m.contains("properties")) {
                    let key = canonicalObject(m)
                    match (counts.get(key)) {
                        case Some(n) => counts[key] = n + 1
                        case None =>
                            counts.add(key, 1)
                            order.add(key)
                    }
                }
                // 继续下探：properties / items / oneOf / anyOf 里的嵌套对象
                for ((_, child) in m) {
                    collectObjects(child, order, counts)
                }
            case JsonValue.Array(items) =>
                for (item in items) {
                    collectObjects(item, order, counts)
                }
            case _ => ()
        }
    }

    /** 对象结构的规范文本（键排序），既作去重键也作 deftype 的定义体。 */
    private static func canonicalObject(m: HashMap<String, JsonValue>): String {
        let keys = ArrayList<String>()
        for ((k, _) in m) {
            keys.add(k)
        }
        sortStrings(keys)

        let sb = StringBuilder()
        sb.append("{")
        var first = true
        for (key in keys) {
            if (!first) {
                sb.append(", ")
            }
            first = false
            sb.append(":${key} ")
            match (m.get(key)) {
                case Some(v) => sb.append(canonical(v))
                case None => sb.append("any")
            }
        }
        sb.append("}")
        sb.toString()
    }

    /** 任意 JSON 片段的规范文本。 */
    private static func canonical(node: JsonValue): String {
        match (node) {
            case JsonValue.Null => "null"
            case JsonValue.Boolean(b) => if (b) { "#t" } else { "#f" }
            case JsonValue.Number(n) => n.toString()
            case JsonValue.String(s) => "\"${s}\""
            case JsonValue.Array(items) =>
                let parts = ArrayList<String>()
                for (item in items) {
                    parts.add(canonical(item))
                }
                "[${String.join(parts.toArray(), delimiter: " ")}]"
            case JsonValue.Map(m) => canonicalObject(m)
        }
    }

    private static func sortStrings(items: ArrayList<String>): Unit {
        let n = items.size
        var i: Int64 = 0
        while (i < n) {
            var j: Int64 = 0
            while (j + 1 < n - i) {
                if (items[j] > items[j + 1]) {
                    let tmp = items[j]
                    items[j] = items[j + 1]
                    items[j + 1] = tmp
                }
                j = j + 1
            }
            i = i + 1
        }
    }

    // ==================== 类型渲染 ====================

    /**
     * 单个工具的调用签名。
     *
     * 渲染成「调用形式 + 参数类型」而不是「声明」，因为模型接下来要**调用**它：
     * `;; (tools::read_file {:path string, :limit (opt number)}) -> string`
     */
    private static func renderSignature(tool: Tool, names: HashMap<String, String>): String {
        let description = tool.description()
        let sb = StringBuilder()
        if (description != "") {
            sb.append(";; ${collapse(description)}\n")
        }
        sb.append(";; (tools::${tool.name()} ${renderParams(tool.schema(), names)}) -> any\n")
        sb.toString()
    }

    /** 参数对象：`{:k T, ...}`；非必填键标 `(opt T)`。 */
    private static func renderParams(schema: JsonValue, names: HashMap<String, String>): String {
        match (schema) {
            case JsonValue.Map(m) =>
                match (m.get("properties")) {
                    case Some(JsonValue.Map(props)) =>
                        let required = requiredKeys(m)
                        let keys = ArrayList<String>()
                        for ((k, _) in props) {
                            keys.add(k)
                        }
                        sortStrings(keys)

                        let parts = ArrayList<String>()
                        for (key in keys) {
                            let isRequired = contains(required, key)
                            match (props.get(key)) {
                                case Some(node) =>
                                    parts.add(":${key} ${renderType(node, names, !isRequired)}")
                                case None => ()
                            }
                        }
                        if (parts.size == 0) {
                            return "{}"
                        }
                        "{${String.join(parts.toArray(), delimiter: ", ")}}"
                    case _ => "{}"
                }
            case _ => "{}"
        }
    }

    /**
     * 类型标记。
     *
     * @param optional 该位置是否允许省略；省略时整体包 `(opt ...)`
     */
    private static func renderType(
        node: JsonValue,
        names: HashMap<String, String>,
        optional: Bool
    ): String {
        let core = renderCoreType(node, names)
        if (optional) {
            // 已经是 (opt ...) 时不重复包裹
            if (core.startsWith("(opt ")) {
                return core
            }
            return "(opt ${core})"
        }
        core
    }

    private static func renderCoreType(node: JsonValue, names: HashMap<String, String>): String {
        match (node) {
            case JsonValue.Map(m) =>
                // 重复结构已抽成命名类型
                if (m.contains("properties")) {
                    let key = canonicalObject(m)
                    match (names.get(key)) {
                        case Some(name) => return name
                        case None => ()
                    }
                }

                // 可空联合：{"type": ["string", "null"]}
                if (let Some(JsonValue.Array(types)) <- m.get("type")) {
                    let nonNull = ArrayList<String>()
                    var nullable = false
                    for (t in types) {
                        match (t) {
                            case JsonValue.String(s) =>
                                if (s == "null") {
                                    nullable = true
                                } else {
                                    nonNull.add(s)
                                }
                            case _ => ()
                        }
                    }
                    if (nullable && nonNull.size >= 1) {
                        return "(opt ${scalarType(nonNull[0])})"
                    }
                    if (nonNull.size == 1) {
                        return scalarType(nonNull[0])
                    }
                }

                // 枚举
                if (let Some(JsonValue.Array(values)) <- m.get("enum")) {
                    let parts = ArrayList<String>()
                    for (v in values) {
                        match (v) {
                            case JsonValue.String(s) => parts.add(":${s}")
                            case JsonValue.Number(n) => parts.add(n.toString())
                            case _ => ()
                        }
                    }
                    if (parts.size > 0) {
                        return "(or ${String.join(parts.toArray(), delimiter: " ")})"
                    }
                }

                // 联合类型
                if (let Some(JsonValue.Array(alts)) <- m.get("oneOf")) {
                    return renderAlternatives(alts, names)
                }
                if (let Some(JsonValue.Array(alts)) <- m.get("anyOf")) {
                    return renderAlternatives(alts, names)
                }

                // 基础类型
                if (let Some(JsonValue.String(t)) <- m.get("type")) {
                    match (t) {
                        case "array" =>
                            match (m.get("items")) {
                                case Some(items) => return "(list ${renderCoreType(items, names)})"
                                case None => return "(list any)"
                            }
                        case "object" =>
                            // 无 properties 的自由对象
                            if (!m.contains("properties")) {
                                return "(map string any)"
                            }
                            return renderParams(node, names)
                        case _ => return scalarType(t)
                    }
                }
                "any"
            case _ => "any"
        }
    }

    private static func renderAlternatives(alts: ArrayList<JsonValue>, names: HashMap<String, String>): String {
        let parts = ArrayList<String>()
        for (alt in alts) {
            parts.add(renderCoreType(alt, names))
        }
        if (parts.size == 0) {
            return "any"
        }
        "(or ${String.join(parts.toArray(), delimiter: " ")})"
    }

    private static func scalarType(name: String): String {
        match (name) {
            case "string" => "string"
            case "number" => "number"
            case "integer" => "number"
            case "boolean" => "bool"
            case "null" => "nil"
            case _ => "any"
        }
    }

    // ==================== 小工具 ====================

    private static func requiredKeys(m: HashMap<String, JsonValue>): ArrayList<String> {
        let keys = ArrayList<String>()
        match (m.get("required")) {
            case Some(JsonValue.Array(items)) =>
                for (item in items) {
                    match (item) {
                        case JsonValue.String(s) => keys.add(s)
                        case _ => ()
                    }
                }
            case _ => ()
        }
        keys
    }

    private static func contains(items: ArrayList<String>, value: String): Bool {
        for (item in items) {
            if (item == value) {
                return true
            }
        }
        false
    }

    /** 描述压成单行，避免提示段里出现不受控的换行。 */
    private static func collapse(text: String): String {
        let sb = StringBuilder()
        var pendingSpace = false
        for (r in text.toRuneArray()) {
            if (r == r'\n' || r == r'\r' || r == r'\t' || r == r' ') {
                pendingSpace = true
            } else {
                if (pendingSpace && sb.size > 0) {
                    sb.append(" ")
                }
                pendingSpace = false
                sb.append(r.toString())
            }
        }
        sb.toString()
    }

    // ==================== 固定文本 ====================

    private static let INSTRUCTIONS: String = """
你可以用 xisp（Lisp 方言）编写程序来组合调用工具。

约定：
- 工具调用写作 (tools::<工具名> {参数})；参数是 hashmap 字面量，键带冒号（:path），
  但取出来是普通字符串键。
- 程序是一个或多个顶层表达式，顺序求值；最后一个表达式的值即本次调用的返回值。
- (println ...) 的内容会作为日志一并返回，不会中断程序。
- 布尔字面量是 #t / #f，nil 是 nil。
- 工具失败会中止程序：失败的调用不会被静默跳过。
- 已提供纯函数：算术、比较、逻辑、列表、高阶（map/filter/reduce）、谓词、hashmap。
  没有文件、进程、模块能力；需要这些请通过工具调用。

参数类型写法：
  T              基础类型：string / number / bool / any
  (opt T)        可省略（也可传 nil）
  (or :a :b)     枚举，取其中之一
  (list T)       同质数组
  (map K V)      映射
  {k T, ...}     对象；键写 :k，值按上面的类型写"""

    private static let EXAMPLE: String = """
示例（对一组输入逐个调用工具，只把结果返回）：
(map (lambda (x) (tools::<工具名> {:<参数名> x})) '("a" "b"))"""
}
