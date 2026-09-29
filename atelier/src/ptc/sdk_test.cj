package atelier.ptc

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.*
import jsonvalue.*
import atelier.tool.*

/**
 * SDK 提示词段生成测试：类型映射、deftype 抽取、字节稳定。
 */
class SchemaTool <: Tool {
    let toolName: String
    let toolSchema: JsonValue

    init(name: String, schema: JsonValue) {
        this.toolName = name
        this.toolSchema = schema
    }

    public func name(): String {
        this.toolName
    }

    public func description(): String {
        "test tool ${this.toolName}"
    }

    public func schema(): JsonValue {
        this.toolSchema
    }

    public func execute(ctx: ToolContext, args: JsonValue): ToolResult {
        ToolResult("", None, false, false)
    }

    public func executionMode(): ToolExecutionMode {
        ToolExecutionMode.Sequential
    }
}

class SdkTestHelpers {
    static func field(typ: String): JsonValue {
        let m = HashMap<String, JsonValue>()
        m.add("type", JsonValue.String(typ))
        JsonValue.Map(m)
    }

    static func enumField(values: Array<String>): JsonValue {
        let m = HashMap<String, JsonValue>()
        m.add("type", JsonValue.String("string"))
        let arr = ArrayList<JsonValue>()
        for (v in values) {
            arr.add(JsonValue.String(v))
        }
        m.add("enum", JsonValue.Array(arr))
        JsonValue.Map(m)
    }

    static func nullable(typ: String): JsonValue {
        let m = HashMap<String, JsonValue>()
        let types = ArrayList<JsonValue>()
        types.add(JsonValue.String(typ))
        types.add(JsonValue.String("null"))
        m.add("type", JsonValue.Array(types))
        JsonValue.Map(m)
    }

    static func listOf(item: JsonValue): JsonValue {
        let m = HashMap<String, JsonValue>()
        m.add("type", JsonValue.String("array"))
        m.add("items", item)
        JsonValue.Map(m)
    }

    /** 构造一个对象 schema；fields 按给定顺序写入，required 决定必填。 */
    static func obj(fields: Array<(String, JsonValue)>, required: Array<String>): JsonValue {
        let props = HashMap<String, JsonValue>()
        for ((k, v) in fields) {
            props.add(k, v)
        }
        let m = HashMap<String, JsonValue>()
        m.add("type", JsonValue.String("object"))
        m.add("properties", JsonValue.Map(props))
        let req = ArrayList<JsonValue>()
        for (r in required) {
            req.add(JsonValue.String(r))
        }
        m.add("required", JsonValue.Array(req))
        JsonValue.Map(m)
    }

    static func tools(items: Array<Tool>): ArrayList<Tool> {
        let list = ArrayList<Tool>()
        for (item in items) {
            list.add(item)
        }
        list
    }
}

@Test
func sdk_emptyToolSetRendersEmpty() {
    @Assert(PtcSdkRenderer.render(ArrayList<Tool>()) == "")
}

@Test
func sdk_basicSignature() {
    let schema = SdkTestHelpers.obj([
        ("path", SdkTestHelpers.field("string")),
        ("limit", SdkTestHelpers.field("integer"))
    ], ["path"])
    let text = PtcSdkRenderer.render(SdkTestHelpers.tools([
        SchemaTool("read_file", schema)
    ]))

    @Assert(text.contains("(tools::read_file {:limit (opt number), :path string}) -> any"))
}

@Test
func sdk_requiredKeysAreNotOptional() {
    let schema = SdkTestHelpers.obj([
        ("a", SdkTestHelpers.field("string")),
        ("b", SdkTestHelpers.field("string"))
    ], ["a"])
    let text = PtcSdkRenderer.render(SdkTestHelpers.tools([SchemaTool("t", schema)]))
    @Assert(text.contains(":a string"))
    @Assert(text.contains(":b (opt string)"))
}

@Test
func sdk_scalarTypeMapping() {
    let schema = SdkTestHelpers.obj([
        ("s", SdkTestHelpers.field("string")),
        ("n", SdkTestHelpers.field("number")),
        ("i", SdkTestHelpers.field("integer")),
        ("b", SdkTestHelpers.field("boolean"))
    ], ["s", "n", "i", "b"])
    let text = PtcSdkRenderer.render(SdkTestHelpers.tools([SchemaTool("t", schema)]))

    @Assert(text.contains(":s string"))
    @Assert(text.contains(":n number"))
    // integer 与 number 都映射为 number
    @Assert(text.contains(":i number"))
    @Assert(text.contains(":b bool"))
}

@Test
func sdk_arrayAndNullable() {
    let schema = SdkTestHelpers.obj([
        ("files", SdkTestHelpers.listOf(SdkTestHelpers.field("string"))),
        ("note", SdkTestHelpers.nullable("string"))
    ], ["files", "note"])
    let text = PtcSdkRenderer.render(SdkTestHelpers.tools([SchemaTool("t", schema)]))

    @Assert(text.contains(":files (list string)"))
    @Assert(text.contains(":note (opt string)"))
}

@Test
func sdk_enumMapping() {
    let schema = SdkTestHelpers.obj([
        ("mode", SdkTestHelpers.enumField(["fast", "slow"]))
    ], ["mode"])
    let text = PtcSdkRenderer.render(SdkTestHelpers.tools([SchemaTool("t", schema)]))
    @Assert(text.contains(":mode (or :fast :slow)"))
}

@Test
func sdk_nestedObjectMapping() {
    let inner = SdkTestHelpers.obj([("name", SdkTestHelpers.field("string"))], ["name"])
    let schema = SdkTestHelpers.obj([("src", inner)], ["src"])
    let text = PtcSdkRenderer.render(SdkTestHelpers.tools([SchemaTool("t", schema)]))
    @Assert(text.contains("{:name string}"))
}

@Test
func sdk_unknownConstructFallsBackToAny() {
    let weird = HashMap<String, JsonValue>()
    weird.add("$ref", JsonValue.String("#/definitions/Thing"))
    let schema = SdkTestHelpers.obj([("x", JsonValue.Map(weird))], ["x"])
    let text = PtcSdkRenderer.render(SdkTestHelpers.tools([SchemaTool("t", schema)]))
    // $ref 在透传层常被丢弃，无法还原真实类型——降级为 any 而不是猜
    @Assert(text.contains(":x any"))
}

@Test
func sdk_extractsRepeatedStructuresIntoDeftype() {
    // JSON Schema 没有可靠的类型复用机制，重复结构必须由生成器自己抽出来
    let shared = SdkTestHelpers.obj([
        ("host", SdkTestHelpers.field("string")),
        ("port", SdkTestHelpers.field("integer"))
    ], ["host", "port"])

    let toolA = SchemaTool("a", SdkTestHelpers.obj([("primary", shared)], ["primary"]))
    let toolB = SchemaTool("b", SdkTestHelpers.obj([("backup", shared)], ["backup"]))
    let text = PtcSdkRenderer.render(SdkTestHelpers.tools([toolA, toolB]))

    @Assert(text.contains("deftype T1"))
    @Assert(text.contains("(tools::a {:primary T1})"))
    @Assert(text.contains("(tools::b {:backup T1})"))
}

@Test
func sdk_singleOccurrenceIsNotExtracted() {
    let only = SdkTestHelpers.obj([("name", SdkTestHelpers.field("string"))], ["name"])
    let tool = SchemaTool("a", SdkTestHelpers.obj([("x", only)], ["x"]))
    let text = PtcSdkRenderer.render(SdkTestHelpers.tools([tool]))
    @Assert(!text.contains("deftype"))
}

@Test
func sdk_toolsAreSortedByName() {
    let a = SchemaTool("zzz", SdkTestHelpers.obj([], []))
    let b = SchemaTool("aaa", SdkTestHelpers.obj([], []))
    let text = PtcSdkRenderer.render(SdkTestHelpers.tools([a, b]))

    let posA = match (text.indexOf("tools::aaa")) {
        case Some(i) => i
        case None => Int64(-1)
    }
    let posZ = match (text.indexOf("tools::zzz")) {
        case Some(i) => i
        case None => Int64(-1)
    }
    @Assert(posA >= 0 && posZ >= 0)
    @Assert(posA < posZ)
}

@Test
func sdk_outputIsByteStable() {
    let schema = SdkTestHelpers.obj([
        ("b", SdkTestHelpers.field("string")),
        ("a", SdkTestHelpers.field("number"))
    ], ["a"])
    let first = PtcSdkRenderer.render(SdkTestHelpers.tools([SchemaTool("t", schema)]))
    // 输入顺序不同也应产出相同文本（提示词前缀缓存依赖这一点）
    let second = PtcSdkRenderer.render(SdkTestHelpers.tools([SchemaTool("t", schema)]))
    @Assert(first == second)

    let reordered = PtcSdkRenderer.render(SdkTestHelpers.tools([
        SchemaTool("t", schema),
        SchemaTool("a", SdkTestHelpers.obj([], []))
    ]))
    let reorderedAgain = PtcSdkRenderer.render(SdkTestHelpers.tools([
        SchemaTool("a", SdkTestHelpers.obj([], [])),
        SchemaTool("t", schema)
    ]))
    @Assert(reordered == reorderedAgain)
}

@Test
func sdk_statesBooleanLiteralSyntax() {
    // 实现期确认的语法事实：布尔字面量是 #t / #f，写 true / false 会得到
    // 未绑定符号（错误值），必须让模型知道
    let text = PtcSdkRenderer.render(SdkTestHelpers.tools([
        SchemaTool("t", SdkTestHelpers.obj([], []))
    ]))
    @Assert(text.contains("#t / #f"))
}

@Test
func sdk_statesFailureSemantics() {
    let text = PtcSdkRenderer.render(SdkTestHelpers.tools([
        SchemaTool("t", SdkTestHelpers.obj([], []))
    ]))
    @Assert(text.contains("工具失败会中止程序"))
}

@Test
func sdk_statesNoFileCapability() {
    let text = PtcSdkRenderer.render(SdkTestHelpers.tools([
        SchemaTool("t", SdkTestHelpers.obj([], []))
    ]))
    @Assert(text.contains("没有文件、进程、模块能力"))
}

@Test
func sdk_includesTypeNotationLegend() {
    let text = PtcSdkRenderer.render(SdkTestHelpers.tools([
        SchemaTool("t", SdkTestHelpers.obj([], []))
    ]))
    @Assert(text.contains("(opt T)"))
    @Assert(text.contains("(or :a :b)"))
    @Assert(text.contains("(list T)"))
}

@Test
func sdk_descriptionIsCollapsedToOneLine() {
    let tool = SchemaTool("t", SdkTestHelpers.obj([], []))
    let text = PtcSdkRenderer.render(SdkTestHelpers.tools([tool]))
    // description 含换行时不得污染签名行
    var commentLines = 0
    for (line in text.split("\n")) {
        if (line.startsWith(";; (tools::t")) {
            commentLines = commentLines + 1
        }
    }
    @Assert(commentLines == 1)
}
