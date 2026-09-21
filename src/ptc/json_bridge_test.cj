package atelier.ptc

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.*
import jsonvalue.*
import ystyle::xisp.types.*
import ystyle::xisp.core.eval.INTERRUPTED_MESSAGE

/**
 * JSON ↔ LispValue 双向转换测试。
 *
 * 注意：`LispValue` 与 `JsonValue` 都未实现 `Equatable`，因此断言一律用
 * 模式匹配或文本比较，不用 `@Expect` 直接比对两个值。
 */
@Test
func jsonBridge_scalars() {
    match (JsonBridge.toLisp(JsonValue.Null)) {
        case LispValue.Nil => @Assert(true)
        case other => @Fail("null should map to Nil, got ${other}")
    }
    match (JsonBridge.toLisp(JsonValue.Boolean(true))) {
        case LispValue.Boolean(b) => @Assert(b)
        case other => @Fail("boolean should map to Boolean, got ${other}")
    }
    match (JsonBridge.toLisp(JsonValue.String("hi"))) {
        case LispValue.Str(s) => @Assert(s == "hi")
        case other => @Fail("string should map to Str, got ${other}")
    }
}

@Test
func jsonBridge_integralNumbersBecomeInt() {
    // JSON 只有 Number(Float64)；整数值必须还原为 Int，
    // 否则脚本拿到 10.0 参与运算会产出浮点结果
    match (JsonBridge.toLisp(JsonValue.Number(10.0))) {
        case LispValue.Int(n) => @Assert(n == 10)
        case other => @Fail("10.0 should map to Int, got ${other}")
    }
    match (JsonBridge.toLisp(JsonValue.Number(-3.0))) {
        case LispValue.Int(n) => @Assert(n == -3)
        case other => @Fail("-3.0 should map to Int, got ${other}")
    }
    match (JsonBridge.toLisp(JsonValue.Number(1.5))) {
        case LispValue.Float(f) => @Assert(f == 1.5)
        case other => @Fail("1.5 should stay Float, got ${other}")
    }
}

@Test
func jsonBridge_scalarsBack() {
    match (JsonBridge.toJson(LispValue.Nil)) {
        case Some(JsonValue.Null) => @Assert(true)
        case other => @Fail("Nil should map to JSON null, got ${other}")
    }
    match (JsonBridge.toJson(LispValue.Boolean(false))) {
        case Some(JsonValue.Boolean(b)) => @Assert(!b)
        case other => @Fail("Boolean should map to JSON boolean, got ${other}")
    }
    match (JsonBridge.toJson(LispValue.Str("hi"))) {
        case Some(JsonValue.String(s)) => @Assert(s == "hi")
        case other => @Fail("Str should map to JSON string, got ${other}")
    }
    match (JsonBridge.toJson(LispValue.Int(10))) {
        case Some(JsonValue.Number(n)) => @Assert(n == 10.0)
        case other => @Fail("Int should map to JSON number, got ${other}")
    }
    match (JsonBridge.toJson(LispValue.Float(2.5))) {
        case Some(JsonValue.Number(n)) => @Assert(n == 2.5)
        case other => @Fail("Float should map to JSON number, got ${other}")
    }
}

@Test
func jsonBridge_arrayToList() {
    let arr = ArrayList<JsonValue>()
    arr.add(JsonValue.Number(1.0))
    arr.add(JsonValue.Number(2.0))

    match (JsonBridge.toLisp(JsonValue.Array(arr))) {
        case Cons(cell) =>
            @Assert(cell.car.toString() == "1")
            match (cell.cdr) {
                case Cons(c2) =>
                    @Assert(c2.car.toString() == "2")
                    @Assert(c2.cdr.toString() == "nil")
                case other => @Fail("expected two-element list, got ${other}")
            }
        case other => @Fail("expected list, got ${other}")
    }
}

@Test
func jsonBridge_listToArray() {
    let lisp = consValue(LispValue.Int(1), consValue(LispValue.Str("x"), LispValue.Nil))
    match (JsonBridge.toJson(lisp)) {
        case Some(JsonValue.Array(items)) =>
            @Assert(items.size == 2)
            match (items[0]) {
                case JsonValue.Number(n) => @Assert(n == 1.0)
                case other => @Fail("first item should be number, got ${other}")
            }
            match (items[1]) {
                case JsonValue.String(s) => @Assert(s == "x")
                case other => @Fail("second item should be string, got ${other}")
            }
        case other => @Fail("expected array, got ${other}")
    }
}

@Test
func jsonBridge_objectToHashMap() {
    // 脚本里的 {...} 字面量本来就是 LispValue.HashMap，映射应是一对一
    let m = HashMap<String, JsonValue>()
    m.add("path", JsonValue.String("a.cj"))
    m.add("limit", JsonValue.Number(10.0))

    match (JsonBridge.toLisp(JsonValue.Map(m))) {
        case LispValue.HashMap(bindings) =>
            @Assert(bindings.size == 2)
            match (bindings.get("path")) {
                case Some(v) => @Assert(v.toString() == "\"a.cj\"")
                case None => @Fail("missing key path")
            }
            match (bindings.get("limit")) {
                case Some(v) => @Assert(v.toString() == "10")
                case None => @Fail("missing key limit")
            }
        case other => @Fail("expected HashMap, got ${other}")
    }
}

@Test
func jsonBridge_roundTripNested() {
    let inner = HashMap<String, JsonValue>()
    inner.add("n", JsonValue.Number(1.0))
    let arr = ArrayList<JsonValue>()
    arr.add(JsonValue.Map(inner))
    arr.add(JsonValue.Boolean(true))
    let outer = HashMap<String, JsonValue>()
    outer.add("items", JsonValue.Array(arr))
    let original = JsonValue.Map(outer)

    let lisp = JsonBridge.toLisp(original)
    let back = JsonBridge.toJson(lisp)

    // 比较两次转换的 Lisp 文本表示（两个枚举都没有 Equatable）
    match (back) {
        case Some(v) => @Assert(JsonBridge.toLisp(v).toString() == lisp.toString())
        case None => @Fail("round trip should produce a value")
    }
}

@Test
func jsonBridge_rejectsNonSerializable() {
    // 过程/闭包/原生函数没有 JSON 对应物，必须报 None 而不是悄悄降级
    let proc = LispValue.Procedure(ArrayList<String>(), LispValue.Nil, Environment())
    match (JsonBridge.toJson(proc)) {
        case None => @Assert(true)
        case other => @Fail("procedure should not be serializable, got ${other}")
    }

    let native = LispValue.NativeFunc({ _ => LispValue.Nil })
    match (JsonBridge.toJson(native)) {
        case None => @Assert(true)
        case other => @Fail("native func should not be serializable, got ${other}")
    }

    let err = LispValue.Error(XispError(ErrorType.RuntimeError, "boom"))
    match (JsonBridge.toJson(err)) {
        case None => @Assert(true)
        case other => @Fail("error value should not be serializable, got ${other}")
    }
}

@Test
func jsonBridge_rejectsImproperList() {
    // 点对 (1 . 2) 不是列表，不能表示成 JSON 数组
    let dotted = consValue(LispValue.Int(1), LispValue.Int(2))
    match (JsonBridge.toJson(dotted)) {
        case None => @Assert(true)
        case other => @Fail("dotted pair should not be serializable, got ${other}")
    }
}

@Test
func jsonBridge_rejectsListWithNonSerializableElement() {
    let bad = consValue(LispValue.Int(1),
        consValue(LispValue.NativeFunc({ _ => LispValue.Nil }), LispValue.Nil))
    match (JsonBridge.toJson(bad)) {
        case None => @Assert(true)
        case other => @Fail("list with a procedure should not be serializable, got ${other}")
    }
}

@Test
func jsonBridge_longArrayDoesNotOverflowStack() {
    // types.list() 按元素递归，实测 10 万元素即 OutOfMemoryError；
    // 本转换器必须迭代构造，否则长工具结果会直接打挂进程
    let arr = ArrayList<JsonValue>()
    for (i in 0..50000) {
        arr.add(JsonValue.Number(Float64(i)))
    }
    let lisp = JsonBridge.toLisp(JsonValue.Array(arr))

    // 往返一次，两个方向都不得爆栈
    match (JsonBridge.toJson(lisp)) {
        case Some(JsonValue.Array(items)) => @Assert(items.size == 50000)
        case other => @Fail("expected 50000-element array, got ${other}")
    }
}

@Test
func jsonBridge_errorHelpers() {
    let err = LispValue.Error(XispError(ErrorType.RuntimeError, "boom"))
    match (JsonBridge.errorMessage(err)) {
        case Some(m) => @Assert(m == "boom")
        case None => @Fail("should extract error message")
    }
    match (JsonBridge.errorMessage(LispValue.Int(1))) {
        case None => @Assert(true)
        case Some(m) => @Fail("non-error should have no message, got ${m}")
    }

    let interrupted = LispValue.Error(XispError(ErrorType.RuntimeError, INTERRUPTED_MESSAGE))
    @Assert(JsonBridge.isInterrupt(interrupted))
    @Assert(!JsonBridge.isInterrupt(err))
    @Assert(!JsonBridge.isInterrupt(LispValue.Int(1)))
}
