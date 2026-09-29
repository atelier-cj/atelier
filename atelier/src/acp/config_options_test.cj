package atelier.acp

import std.collection.*
import acp.types.SessionConfigOption
import jsonvalue.*

func modelOptions(): ArrayList<String> {
    let m = ArrayList<String>()
    m.add("deepseek-chat")
    m.add("gpt-4o")
    m.add("deepseek-chat")   // 重复项应被去重
    m
}

// 列表完整：model（select + model_config 类目）+ compaction（boolean），顺序 model 在前
@Test
func configOptions_optionListShape() {
    let co = AcpConfigOptions(modelOptions(), "gpt-4o", true)
    let list = co.optionList()
    @Expect(list.size, 2)
    let m = list[0]
    @Expect(m.id, "model")
    @Expect(m.`type`, "select")
    @Expect(m.name, "模型")
    match (m.category) {
        case Some(c) => @Expect(c, "model_config")
        case None => @Fail("model option missing category")
    }
    match (m.currentValue) {
        case Some(v) => @Expect(v, "gpt-4o")
        case None => @Fail("model option missing currentValue")
    }
    match (m.options) {
        case Some(vals) =>
            @Expect(vals.size, 2)
            @Expect(vals[0].value, "deepseek-chat")
            @Expect(vals[1].value, "gpt-4o")
        case None => @Fail("model option missing options")
    }
    let c = list[1]
    @Expect(c.id, "compaction")
    @Expect(c.`type`, "boolean")
    match (c.currentBool) {
        case Some(v) => @Expect(v, true)
        case None => @Fail("compaction option missing currentBool")
    }
}

// 默认模型不在候选集时自动并入
@Test
func configOptions_defaultModelAlwaysSelectable() {
    let m = ArrayList<String>()
    m.add("deepseek-chat")
    let co = AcpConfigOptions(m, "custom-model", true)
    let list = co.optionList()
    match (list[0].options) {
        case Some(vals) =>
            @Expect(vals.size, 2)
            @Expect(vals[1].value, "custom-model")
        case None => @Fail("options missing")
    }
    @Expect(co.effectiveModel(), "custom-model")
}

// setOption：合法模型切换生效；候选外/非字符串 → false 且不变
@Test
func configOptions_setModelValidates() {
    let co = AcpConfigOptions(modelOptions(), "gpt-4o", true)
    @Expect(co.setOption("model", JsonValue.String("deepseek-chat")), true)
    @Expect(co.effectiveModel(), "deepseek-chat")
    @Expect(co.setOption("model", JsonValue.String("not-a-model")), false)
    @Expect(co.effectiveModel(), "deepseek-chat")
    @Expect(co.setOption("model", JsonValue.Boolean(true)), false)
    @Expect(co.setOption("nope", JsonValue.String("x")), false)
}

// setOption：compaction 布尔开关
@Test
func configOptions_setCompactionToggle() {
    let co = AcpConfigOptions(modelOptions(), "gpt-4o", true)
    @Expect(co.setOption("compaction", JsonValue.Boolean(false)), true)
    @Expect(co.effectiveCompaction(), false)
    @Expect(co.setOption("compaction", JsonValue.String("x")), false)
    @Expect(co.effectiveCompaction(), false)
}

// reset 恢复默认（会话关闭后重建语义）
@Test
func configOptions_resetRestoresDefaults() {
    let co = AcpConfigOptions(modelOptions(), "gpt-4o", true)
    co.setOption("model", JsonValue.String("deepseek-chat"))
    co.setOption("compaction", JsonValue.Boolean(false))
    co.reset()
    @Expect(co.effectiveModel(), "gpt-4o")
    @Expect(co.effectiveCompaction(), true)
    // reset 后 optionList 反映默认
    match (co.optionList()[0].currentValue) {
        case Some(v) => @Expect(v, "gpt-4o")
        case None => @Fail("currentValue missing after reset")
    }
}
