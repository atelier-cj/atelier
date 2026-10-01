package atelier.context

import atelier.message.*
import std.collection.*
import atelier.provider.ModelInfo
import jsonvalue.*

func msg(text: String): Message {
    UserMessage(ContentList.ofText(text), 0)
}

@Test
func estimateText() {
    let t = estimateTextTokens("hello world")
    @Expect(t > 0, true)
}

@Test
func compactSpec_thresholdIsMinOfRatioAndPressureBudget() {
    let cc = CompactionConfig()   // ratio 0.8 / headroom 65536
    // W=200000, O=8192 → messageBudget=191808, pressureBudget=126272
    // 0.8×W=160000 > pressureBudget → 取 pressureBudget
    let r = resolveCompactSpec(cc, 200000, 8192)
    match (r.spec) {
        case Some(spec) =>
            @Expect(spec.messageBudget, 191808)
            @Expect(spec.thresholdTokens, 126272)
            // retain = messageBudget × 0.16
            @Expect(spec.retainTokens, Int64(Float64(191808) * 0.16))
            // 摘要输出上限默认跟随 headroom
            @Expect(spec.summaryMaxTokens, 65536)
        case None => @Fail("spec should resolve: " + r.reason)
    }

    // 中小窗口：默认 64k 余量吃掉大部分压力预算 → 取 pressureBudget（这正是"小窗口要自己调余量"）
    let narrow = resolveCompactSpec(cc, 100000, 8192)
    match (narrow.spec) {
        case Some(spec) => @Expect(spec.thresholdTokens, 26272)
        case None => @Fail("spec should resolve: " + narrow.reason)
    }

    // 收紧余量后：0.8×W 才是更小的那一侧
    let tightened = CompactionConfig(true, 0.8, 1024, 0.16, None, 1, DEFAULT_PROMPT_TEMPLATE, None, None)
    match (resolveCompactSpec(tightened, 100000, 8192).spec) {
        case Some(spec) => @Expect(spec.thresholdTokens, 80000)
        case None => @Fail("spec should resolve")
    }
}

@Test
func compactSpec_invariantsBecomeReasons() {
    let cc = CompactionConfig()
    // 窗口未知：不压缩（也不该猜）
    match (resolveCompactSpec(cc, 0, 8192).spec) {
        case None => ()
        case Some(_) => @Fail("unknown window must not compact")
    }
    // 输出预留吃掉整个窗口
    match (resolveCompactSpec(cc, 8192, 8192).spec) {
        case None => ()
        case Some(_) => @Fail("zero message budget must not compact")
    }
    // 余量吃掉整个消息预算
    let tight = CompactionConfig(true, 0.8, 8192, 0.16, None, 1, DEFAULT_PROMPT_TEMPLATE, None, None)
    match (resolveCompactSpec(tight, 16384, 8192).spec) {
        case None => ()
        case Some(_) => @Fail("zero pressure budget must not compact")
    }
    // 保留不小于阈值
    let bad = CompactionConfig(true, 0.8, 65536, 0.16, Some(999999), 1, DEFAULT_PROMPT_TEMPLATE, None, None)
    let r = resolveCompactSpec(bad, 200000, 8192)
    match (r.spec) {
        case None => @Expect(r.reason.contains("retain"), true)
        case Some(_) => @Fail("retain >= threshold must not compact")
    }
}

@Test
func compactSpec_absoluteRetainWins() {
    let cc = CompactionConfig(true, 0.8, 1024, 0.16, Some(4096), 1, DEFAULT_PROMPT_TEMPLATE, None, None)
    match (resolveCompactSpec(cc, 100000, 8192).spec) {
        case Some(spec) => @Expect(spec.retainTokens, 4096)
        case None => @Fail("spec should resolve")
    }
}

@Test
func modelRegistry_unknownModelDefaults() {
    let reg = ModelContextRegistry()
    @Expect(reg.get("unknown-model-123"), reg.defaultContextWindow)
}

@Test
func modelRegistry_hasDistinguishesKnownFromFallback() {
    let reg = ModelContextRegistry()
    reg.register("declared-model", ModelInfo(65536, 8192))
    @Expect(reg.has("declared-model"), true)
    // 未声明的模型：get 给兜底值，但 has = false —— 调用方据此留痕，
    // 不然会静默按偏小的窗口提前压缩。
    // 注意内置目录（llm_api 的 ModelCatalog）不在本表里：它由 provider 自报那一层提供
    @Expect(reg.has("vendor-new-model"), false)
    @Expect(reg.has("gpt-4o"), false)
    @Expect(reg.get("vendor-new-model"), reg.defaultContextWindow)
}

@Test
func modelRegistry_providerLayerOverridesNameLayer() {
    let reg = ModelContextRegistry()
    reg.register("vendor-model", 111)
    reg.registerFor("proxy", "vendor-model", ModelInfo(32768, 4096))

    // 端点层：同一模型名在不同端点下各是各的
    @Expect(reg.windowFor("proxy", "vendor-model"), Some(32768))
    @Expect(reg.hasFor("proxy", "vendor-model"), true)
    @Expect(reg.windowFor("other", "vendor-model"), None)
    @Expect(reg.hasFor("other", "vendor-model"), false)
    // 模型名层不受端点层影响
    @Expect(reg.get("vendor-model"), 111)

    // 派生：端点层声明落在副本上，原表不动
    let derived = reg.mergedFor("other", "vendor-model", ModelInfo(4096, 1024))
    @Expect(derived.windowFor("other", "vendor-model"), Some(4096))
    @Expect(reg.hasFor("other", "vendor-model"), false)
    // 已有层照旧带过去
    @Expect(derived.windowFor("proxy", "vendor-model"), Some(32768))
    @Expect(derived.get("vendor-model"), 111)
}

@Test
func modelRegistry_listCoversBothLayers() {
    let reg = ModelContextRegistry()
    reg.register("only-name", 1000)
    reg.registerFor("p", "only-endpoint", ModelInfo(2000, 0))
    let names = reg.list()
    @Expect(names.contains("only-name"), true)
    // list() 只列**显式声明**过的名字：provider 自报/内置目录不在这张表里
    @Expect(names.contains("gpt-4o"), false)
}

@Test
func modelRegistry_mergedOverridesOnCopy() {
    let base = ModelContextRegistry()
    let derived = base.merged("vendor-new-model", ModelInfo(262144, 8192))

    @Expect(derived.get("vendor-new-model"), 262144)
    @Expect(derived.has("vendor-new-model"), true)
    // 原表不动
    @Expect(base.has("vendor-new-model"), false)
    // 其它声明照旧带过来
    @Expect(derived.has("vendor-new-model"), true)
}

@Test
func modelRegistry_defaultWindowIsConfigurable() {
    let reg = ModelContextRegistry(defaultWindow: 32768, defaultMaxTokens: 2048)
    @Expect(reg.get("unknown-model-xyz"), 32768)
    @Expect(reg.defaultMaxTokens, 2048)

    let narrower = reg.withDefaults(4096, 1024)
    @Expect(narrower.get("unknown-model-xyz"), 4096)
    // 换兜底不影响已知条目
    @Expect(narrower.has("vendor-new-model"), false)
    @Expect(reg.defaultContextWindow, 32768)
}

@Test
func compactionConfig_defaultTemplateRenders() {
    let cfg = CompactionConfig()
    let out = renderCompactionPrompt(cfg, "对话内容", None, 16384)
    // 默认模板**不内联对话**：被压区域以消息形式回放，指令单独追加
    // （内联会让前缀与主请求不同，DeepSeek 的硬盘缓存按"缓存前缀单元完整匹配"计费）
    @Expect(out.contains("<conversation>"), false)
    @Expect(out.contains("对话内容"), false)
    // dsh 的检查点骨架：每节都在，一节不能少
    for (section in ["## Primary Request and Intent", "## Key Technical Concepts", "## Files and Code",
        "## Errors and Fixes", "## Pending Jobs", "## Current Work", "## Next Step", "## Critical Context"]) {
        @Expect(out.contains(section), true)
    }
    // 空节写 "(none)"、不照抄上一份检查点这两条硬规则要在
    @Expect(out.contains("(none)"), true)
    @Expect(out.contains("上一份检查点"), true)
    // 默认模板也不内联历史摘要：区域里若有上一份检查点，它本身就在回放的消息里
    @Expect(out.contains("<previous_summary>"), false)
}

@Test
func compactionConfig_previousSummaryConditional() {
    // 默认模板已不用它（历史摘要随区域回放），但自定义模板仍可引用
    let cfg = CompactionConfig(true, 0.8, 16384, 0.16, None, 1,
        "{{#previous_summary}}<previous_summary>\n{{previous_summary}}\n</previous_summary>{{/previous_summary}}\n对话：{{conversation}}",
        None, None)
    let out = renderCompactionPrompt(cfg, "对话内容", Some("历史摘要"), 16384)
    @Expect(out.contains("<previous_summary>\n历史摘要\n</previous_summary>"), true)
    @Expect(out.contains("对话：对话内容"), true)
}

@Test
func compactionConfig_customTemplate() {
    let cfg = CompactionConfig(
        true, 0.8, 16384, 0.16, None, 1,
        "压缩以下对话：\n{{conversation}}\n{{#previous_summary}}旧摘要：{{previous_summary}}{{/previous_summary}}",
        None, None)
    let out = renderCompactionPrompt(cfg, "对话", Some("旧"), 16384)
    @Expect(out.contains("旧摘要：旧"), true)
    let out2 = renderCompactionPrompt(cfg, "对话", None, 16384)
    @Expect(out2.contains("旧摘要"), false)
}

@Test
func compactionConfig_schemaValid() {
    let cfg = CompactionConfig()
    let schema = JsonValue.parse("{\"required\":[\"goal\"],\"types\":{\"goal\":\"string\"}}")
    match (schema) {
        case JsonValue.Map(m) =>
            @Expect(validateSummary(cfg, m, "{\"goal\":\"完成\"}"), true)
            @Expect(validateSummary(cfg, m, "{\"goal\":123}"), false)
            @Expect(validateSummary(cfg, m, "{\"other\":\"x\"}"), false)
        case _ => @Fail("schema parse failed")
    }
}

@Test
func compactionConfig_summaryReplacesAllWhenKeepZero() {
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("a"), 0))
    msgs.add(UserMessage(ContentList.ofText("b"), 0))
    let out = compactWithSummary(msgs, 0, "摘要", 10)
    @Expect(out.size, 1)
    match (out[0]) {
        case cm: CompactionMessage => @Expect(checkpointBody(cm.summary), "摘要")
        case _ => @Fail("expected CompactionMessage")
    }
}

@Test
func compactionConfig_summaryKeepsRecent() {
    let msgs = ArrayList<Message>()
    for (i in 0..=5) { msgs.add(UserMessage(ContentList.ofText("消息${i}"), 0)) }
    let out = compactWithSummary(msgs, 100000, "摘要", 10)
    @Expect(out.size, 6)
    var hasSummary = false
    for (m in out) {
        match (m) {
            case cm: CompactionMessage => hasSummary = true
            case _ => ()
        }
    }
    @Expect(hasSummary, false)
}

func bigText(): String {
    let sb = StringBuilder()
    var i: Int64 = 0
    while (i < 100) { sb.append("x"); i++ }
    sb.toString()
}

// 回归：单条消息即超过 keepRecent 预算时，切点必须落在该消息之后（此前 i-- 过度导致 cutIndex=0 不压缩）
@Test
func compactWithSummary_singleBigMessageTriggersCut() {
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText(bigText()), 0))  // 30 tokens
    msgs.add(UserMessage(ContentList.ofText("tail"), 0))     // 6 tokens
    let out = compactWithSummary(msgs, 10, "摘要", 36)
    @Expect(out.size, 2)
    match (out[0]) {
        case cm: CompactionMessage => @Expect(checkpointBody(cm.summary), "摘要")
        case _ => @Fail("expected CompactionMessage")
    }
    match (out[1]) {
        case um: UserMessage => @Expect(um.content.blocks().size, 1)
        case _ => @Fail("expected tail user message")
    }
}

// 多消息：累加到从尾数第 2 条时达标，切点在该条之后（尾部保留）
@Test
func compactWithSummary_multiMessageReach() {
    let msgs = ArrayList<Message>()
    for (i in 0..6) { msgs.add(UserMessage(ContentList.ofText("m"), 0)) }  // 每条 5 tokens
    let out = compactWithSummary(msgs, 8, "摘要", 30)
    @Expect(out.size, 2)
    match (out[0]) {
        case cm: CompactionMessage => @Expect(checkpointBody(cm.summary), "摘要")
        case _ => @Fail("expected CompactionMessage")
    }
    match (out[1]) {
        case um: UserMessage =>
            match (um.content.blocks()[0]) {
                case ContentBlock.TextBlock(t) => @Expect(t, "m")
                case _ => @Fail("expected text block")
            }
        case _ => @Fail("expected tail user message")
    }
}

// 回归：previous_summary 提取最近一条历史摘要（CompactionMessage/ArchiveMessage），
// 普通消息夹在中间不影响提取，无摘要时返回 None
@Test
func compactionConfig_findPreviousSummary() {
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("a"), 0))
    @Expect(findPreviousSummary(msgs), None)
    msgs.add(CompactionMessage("旧摘要", 100, 0))
    @Expect(findPreviousSummary(msgs), Some("旧摘要"))
    msgs.add(UserMessage(ContentList.ofText("b"), 0))
    @Expect(findPreviousSummary(msgs), Some("旧摘要"))
    msgs.add(ArchiveMessage(0, 1, "归档摘要", 0))
    @Expect(findPreviousSummary(msgs), Some("归档摘要"))
}

func toolPairMsg(tcId: String, toolName: String): ArrayList<Message> {
    let r = ArrayList<Message>()
    let tc = ToolCallBlock(tcId, toolName, JsonValue.Map(HashMap()))
    let blocks = ArrayList<ContentBlock>()
    blocks.add(ContentBlock.ToolCall(tc))
    r.add(AssistantMessage(ContentList(blocks), "", "", StopReason.ToolUse, TokenUsage(0, 0), 0))
    r.add(ToolResultMessage(tcId, toolName, ContentList.ofText("结果"), false, 0))
    r
}

@Test
func compactionConfig_cutPreservesToolPair() {
    // 场景 a：cutIndex 切在 ToolResult 处（ToolCall 在移除区）→ 前移保留 ToolCall
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("m0"), 0))
    let pair = toolPairMsg("c1", "read_file")
    msgs.add(pair[0])
    msgs.add(pair[1])
    msgs.add(UserMessage(ContentList.ofText("m1"), 0))
    // 构造 keepRecent 极小 → cutIndex 会落在 ToolResult 附近；用 protectCutPoint 直接测
    let cut = protectCutPoint(msgs, 2)
    @Expect(cut, 1)  // 前移到 ToolCall 位置，配对完整保留
}

@Test
func compactionConfig_cutMovesPastOrphanResult() {
    // 场景 b：移除区最后一条含 ToolCall 且其 ToolResult 在保留区 → 后移整体移除
    // 构造：ToolResult 与 ToolCall 间隔一条 UserMessage，保留区第一条非 ToolResult，
    // 规则 a 不会抢先触发，恰好命中规则 b 的后移路径
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("m0"), 0))
    let pair = toolPairMsg("c2", "bash")
    msgs.add(pair[0])
    msgs.add(UserMessage(ContentList.ofText("m1"), 0))
    msgs.add(pair[1])
    msgs.add(UserMessage(ContentList.ofText("m2"), 0))
    let cut = protectCutPoint(msgs, 2)
    @Expect(cut, 4)  // 后移到 ToolResult 之后，整个对移除
}

@Test
func compactionConfig_cutNoPairUnchanged() {
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("m0"), 0))
    msgs.add(UserMessage(ContentList.ofText("m1"), 0))
    @Expect(protectCutPoint(msgs, 1), 1)
}

@Test
func compactionConfig_cutCrossPairsConverges() {
    // 交叉配对 [A(t1), A(t2), TR(t1), TR(t2)]：规则 a（前移）与规则 b（后移）互相拉扯，
    // 迭代式实现会 1 ↔ 3 无限振荡；必须收敛到配对完整的全局合法切点
    let msgs = ArrayList<Message>()
    let p1 = toolPairMsg("t1", "read_file")
    let p2 = toolPairMsg("t2", "bash")
    msgs.add(p1[0])
    msgs.add(p2[0])
    msgs.add(p1[1])
    msgs.add(p2[1])
    msgs.add(UserMessage(ContentList.ofText("m1"), 0))
    let cut = protectCutPoint(msgs, 3)
    @Expect(cut, 0)  // 前移保留全部对，配对完整
}

// ---------- 溢出恢复的纯函数 ----------

@Test
func overflowErrorMatcher_knownPhrasings() {
    // 各家措辞不同：按已知措辞匹配，大小写不敏感
    @Expect(isContextOverflowError("Error 400: This model's maximum context length is 8192 tokens"), true)
    @Expect(isContextOverflowError("invalid_request_error: context_length_exceeded"), true)
    @Expect(isContextOverflowError("prompt is too long: 210000 tokens > 200000 maximum"), true)
    @Expect(isContextOverflowError("Input is too long for requested model"), true)
    @Expect(isContextOverflowError("Please reduce the length of the messages"), true)
    // 无关错误不能误判（误判会白花一次摘要调用）
    @Expect(isContextOverflowError("connection reset by peer"), false)
    @Expect(isContextOverflowError("401 Unauthorized: invalid api key"), false)
    @Expect(isContextOverflowError(""), false)
}

@Test
func compactFrom_keepsTailAndProtectsPairing() {
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("m1"), 0))
    msgs.add(AssistantMessage(ContentList.ofText("a1"), "", "", StopReason.EndTurn, TokenUsage(0, 0), 0))
    msgs.add(UserMessage(ContentList.ofText("m2"), 0))

    // 保留最后一条用户消息起的内容，前面换成摘要
    @Expect(lastUserIndex(msgs), 2)
    let out = compactFrom(msgs, 2, "摘要", 100)
    @Expect(out.size, 2)
    match (out[0]) {
        case cm: CompactionMessage => @Expect(checkpointBody(cm.summary), "摘要")
        case _ => @Fail("expected CompactionMessage first")
    }
    match (out[1]) {
        case um: UserMessage => @Expect(um.content.blocks().size, 1)
        case _ => @Fail("expected tail user message")
    }

    // 切点落在 0 = 没有可压的头部 → 原样返回（绝不把事情弄得更糟）
    @Expect(compactFrom(msgs, 0, "摘要", 100).size, 3)
}

@Test
func lastUserIndex_noneWhenNoUserMessage() {
    let msgs = ArrayList<Message>()
    msgs.add(AssistantMessage(ContentList.ofText("a1"), "", "", StopReason.EndTurn, TokenUsage(0, 0), 0))
    @Expect(lastUserIndex(msgs), -1)
}

// ---------- 工具结果修剪 ----------

func repeatText(unit: String, times: Int64): String {
    let sb = StringBuilder()
    var i = 0
    while (i < times) {
        sb.append(unit)
        i++
    }
    sb.toString()
}

@Test
func pruneText_belowThresholdUntouched() {
    let cfg = ToolResultPruneConfig()
    let small = repeatText("abc", 10)   // 30 码点 < 8192
    @Expect(pruneText(small, cfg), small)
}

@Test
func pruneText_keepsHeadAndTailWithMarker() {
    let cfg = ToolResultPruneConfig(true, 100, 40, 20)
    let text = "H" + repeatText("m", 200) + "T"
    let out = pruneText(text, cfg)
    @Expect(out.contains(PRUNE_MARKER), true)
    @Expect(out.startsWith("H" + repeatText("m", 39)), true)
    @Expect(out.endsWith("T"), true)
    // 修剪必须让文本变短
    @Expect(Int64(out.toRuneArray().size) < Int64(text.toRuneArray().size), true)
}

@Test
func pruneText_neverGrowsEvenWithBadConfig() {
    // 头 + 标记 + 尾 > 阈值：自动收紧尾部，绝不比原文更短不了
    let cfg = ToolResultPruneConfig(true, 50, 40, 40)
    let text = repeatText("x", 200)
    let out = pruneText(text, cfg)
    @Expect(Int64(out.toRuneArray().size) <= 50, true)
    @Expect(Int64(out.toRuneArray().size) < Int64(text.toRuneArray().size), true)
}

@Test
func pruneText_countsCodePointsNotBytes() {
    // 每个 emoji 都是多字节但只算一个码点：按码点切不会劈开它们
    let cfg = ToolResultPruneConfig(true, 40, 4, 3)
    let text = repeatText("🙂", 60)   // 60 码点 > 阈值 40
    let out = pruneText(text, cfg)
    var emojiCount: Int64 = 0
    for (r in out.toRuneArray()) {
        if (r == Rune(UInt32(0x1F642))) { emojiCount++ }
    }
    @Expect(emojiCount, 7)   // head 4 + tail 3，中间是标记
}

@Test
func pruneToolResults_onlyOversizedTextBlocks() {
    let cfg = ToolResultPruneConfig(true, 100, 40, 20)
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("问"), 0))
    msgs.add(ToolResultMessage("c1", "bash", ContentList.ofText(repeatText("y", 500)), false, 0))
    msgs.add(ToolResultMessage("c2", "read_file", ContentList.ofText("短结果"), false, 0))

    let (out, count) = pruneToolResults(msgs, cfg)
    @Expect(count, Int64(1))
    @Expect(out.size, 3)
    // 原列表不动（只有发给模型的请求用修剪版，落库的历史保持原样）
    match (msgs[1]) {
        case tr: ToolResultMessage =>
            @Expect(Int64(textOfMsg(tr).toRuneArray().size), Int64(500))
        case _ => @Fail("expected tool result")
    }
    // 修剪版变短且带标记
    match (out[1]) {
        case tr: ToolResultMessage =>
            @Expect(textOfMsg(tr).contains(PRUNE_MARKER), true)
            @Expect(Int64(textOfMsg(tr).toRuneArray().size) < Int64(500), true)
        case _ => @Fail("expected tool result")
    }
    // 小结果原样
    match (out[2]) {
        case tr: ToolResultMessage => @Expect(textOfMsg(tr), "短结果")
        case _ => @Fail("expected small tool result")
    }
}

@Test
func pruneToolResults_disabledIsNoOp() {
    let cfg = ToolResultPruneConfig(false, 100, 40, 20)
    let msgs = ArrayList<Message>()
    msgs.add(ToolResultMessage("c1", "bash", ContentList.ofText(repeatText("y", 500)), false, 0))
    let (out, count) = pruneToolResults(msgs, cfg)
    @Expect(count, Int64(0))
    match (out[0]) {
        case tr: ToolResultMessage => @Expect(Int64(textOfMsg(tr).toRuneArray().size), Int64(500))
        case _ => @Fail("expected untouched tool result")
    }
}

// ---------- 检查点框架（前言 + 标签） ----------

@Test
func checkpointFrame_wrapsAndUnwraps() {
    let framed = frameCheckpoint("裸摘要内容")
    // 模型看到的是"既定背景"，不是一条新指令
    @Expect(framed.startsWith(COMPACTION_CHECKPOINT_PREAMBLE), true)
    @Expect(framed.contains(SUMMARY_OPEN_TAG + "\n裸摘要内容\n" + SUMMARY_CLOSE_TAG), true)
    // 显示/复用要拿回裸摘要
    @Expect(checkpointBody(framed), "裸摘要内容")
    // 旧会话里的裸摘要（没有框架）原样返回，不报错也不截断
    @Expect(checkpointBody("旧格式的摘要"), "旧格式的摘要")
}

@Test
func checkpointFrame_replacementMessageCarriesFraming() {
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("m1"), 0))
    msgs.add(UserMessage(ContentList.ofText("m2"), 0))
    let compacted = compactWithSummary(msgs, 1, "SUM", 100)
    match (compacted[0]) {
        case cm: CompactionMessage =>
            // 落库的替换消息就带框架：模型看到的即所存的（回放/续跑一致）
            @Expect(cm.summary.startsWith(COMPACTION_CHECKPOINT_PREAMBLE), true)
            @Expect(checkpointBody(cm.summary), "SUM")
        case _ => @Fail("expected CompactionMessage")
    }
}

@Test
func checkpointFrame_findPreviousSummaryStripsFraming() {
    let msgs = ArrayList<Message>()
    msgs.add(CompactionMessage(frameCheckpoint("上一份摘要"), 10, 0))
    msgs.add(UserMessage(ContentList.ofText("m"), 0))
    match (findPreviousSummary(msgs)) {
        case Some(s) => @Expect(s, "上一份摘要")
        case None => @Fail("expected previous summary")
    }
}

// ---------- 压缩事务台账 ----------

@Test
func compactionLedger_mutualExclusionPerSession() {
    let ledger = CompactionLedger()
    @Expect(ledger.begin("s1", "c1"), true)
    // 同一会话已有在飞 → 后来者拿不到（要跳过，不是排队）
    @Expect(ledger.begin("s1", "c2"), false)
    @Expect(ledger.isOpen("s1"), true)
    match (ledger.openId("s1")) {
        case Some(v) => @Expect(v, "c1")
        case None => @Fail("expected open id")
    }
    // 别的会话不受影响
    @Expect(ledger.begin("s2", "c3"), true)
    // 释放后可再次登记
    ledger.end("s1")
    @Expect(ledger.isOpen("s1"), false)
    @Expect(ledger.begin("s1", "c4"), true)
}
