package cli

import pulldown4cj.*
import ystyle::xisp_terminal.runeDisplayWidth
import std.collection.*

// ═══════ Markdown → ANSI 终端渲染（pulldown4cj 事件流）═══════════
// 段式累积：每段 = (可见文本, 样式前缀)，wrap 按可见宽度切段、两半各保留样式；
// 块级样式（标题/引用/代码/列表前缀）在每行行首经 blockPrefix 生成。

// ANSI 样式（暗色主题色系）
let M_RESET: String = "\u{1b}[0m"
let M_BOLD: String = "\u{1b}[1m"
let M_ITALIC: String = "\u{1b}[3m"
let M_STRIKE: String = "\u{1b}[9m"
let M_CODE: String = "\u{1b}[33m"        // 行内码：黄
let M_HEADING: String = "\u{1b}[1;36m"   // 标题：粗青
let M_QUOTE: String = "\u{1b}[2;90m"     // 引用：暗灰
let M_URL: String = "\u{1b}[2;36m"       // 链接 URL：暗青
let M_RULE: String = "\u{1b}[2;90m"      // 分隔线：暗灰

class MdRender {
    var out = ArrayList<String>()
    var segs = ArrayList<(String, String)>()   // (可见文本, 样式前缀)
    var visible: Int64 = 0
    var lastSpace: Int64 = -1
    var styles = ArrayList<String>()           // 内联样式栈
    var width: Int64
    var budget: Int64
    var atLineStart: Bool = true
    var quoteDepth: Int64 = 0
    var listDepth: Int64 = 0
    var listNumber: Int64 = 0                  // >0 有序编号；0 无序
    var headingLevel: Int64 = 0
    var inCodeBlock: Bool = false
    var linkUrl: String = ""
    var pendingStyle: String = ""
    var listMarkerEmitted: Bool = false

    public init(width: Int64, prefixWidth: Int64) {
        this.width = width
        this.budget = width - prefixWidth
    }

    func curStyle(): String {
        var s = ""
        for (st in this.styles) { s = s + st }
        s
    }

    // 行首块级前缀（引用标记/列表缩进+项目符号/标题 #/代码块样式）
    func blockPrefix(): (String, String) {
        var text = ""
        var style = ""
        for (i in 0..this.quoteDepth) { text = text + "│ " }
        if (this.quoteDepth > 0) { style = style + M_QUOTE }
        if (this.listDepth > 0) {
            for (i in 0..(this.listDepth - 1)) { text = text + "  " }
            if (!this.listMarkerEmitted) {
                if (this.listNumber > 0) {
                    text = text + this.listNumber.toString() + ". "
                    this.listNumber = this.listNumber + 1
                } else {
                    text = text + "• "
                }
                this.listMarkerEmitted = true
            }
        }
        if (this.headingLevel > 0) {
            style = style + M_HEADING + M_BOLD
            for (i in 0..this.headingLevel) { text = text + "#" }
            text = text + " "
        } else if (this.inCodeBlock) {
            style = style + M_CODE
        }
        (text, style)
    }

    // 追加文本段（带内联样式；行首先放块前缀并把块样式挂为 pendingStyle 贯穿本行）
    func append(text: String, style!: String = ""): Unit {
        if (text == "") { return }
        if (this.atLineStart) {
            let (pre, preStyle) = this.blockPrefix()
            if (pre != "") {
                this.segs.add((pre, preStyle + this.curStyle()))
                this.visible = this.visible + plainWidth(pre)
            }
            this.pendingStyle = preStyle
            this.atLineStart = false
        }
        // 文本内的换行拆段（代码块 Text 常带 \n）
        let parts = text.split("\n")
        for (i in 0..parts.size) {
            if (i > 0) { this.flushLine() }
            let part = parts[Int64(i)]
            if (part == "") { continue }
            this.segs.add((part, this.pendingStyle + style + this.curStyle()))
            let runes = part.toRuneArray()
            for (r in runes) {
                this.visible = this.visible + runeDisplayWidth(r)
                if (r == Rune(UInt32(0x20))) { this.lastSpace = this.visible }
            }
            if (this.visible > this.budget) { this.wrap() }
        }
    }

    func plainWidth(s: String): Int64 {
        var w: Int64 = 0
        for (r in s.toRuneArray()) { w = w + runeDisplayWidth(r) }
        w
    }

    // 行溢出：优先在最近空格断行，否则预算边界硬切
    func wrap(): Unit {
        let target = if (this.lastSpace > 0) { this.lastSpace } else { this.budget }
        var cut = ArrayList<(String, String)>()
        var rest = ArrayList<(String, String)>()
        var w: Int64 = 0
        var inFirst = true
        for (i in 0..this.segs.size) {
            let (t, st) = this.segs[Int64(i)]
            let tw = plainWidth(t)
            if (inFirst && w + tw <= target) {
                cut.add((t, st))
                w = w + tw
            } else if (inFirst) {
                // 段内拆分：前半进本行，后半进续行（样式各保留）
                let need = target - w
                if (need > 0) {
                    let runes = t.toRuneArray()
                    var part1 = ArrayList<Rune>()
                    var part2 = ArrayList<Rune>()
                    var pw: Int64 = 0
                    for (r in runes) {
                        let dw = runeDisplayWidth(r)
                        if (pw + dw <= need) {
                            part1.add(r)
                            pw = pw + dw
                        } else {
                            part2.add(r)
                        }
                    }
                    if (part1.size > 0) { cut.add((String(part1), st)) }
                    if (part2.size > 0) { rest.add((String(part2), st)) }
                }
                inFirst = false
            } else {
                rest.add((t, st))
            }
        }
        this.emitLine(cut)
        this.segs = rest
        var restVisible: Int64 = 0
        for ((t, _) in rest) { restVisible = restVisible + plainWidth(t) }
        this.visible = restVisible
        this.lastSpace = -1
        this.budget = this.width
        // 续行行首重新生成块前缀（引用/标题样式延续）
        this.atLineStart = true
        if (this.visible > this.budget) { this.wrap() }
    }

    func emitLine(segs: ArrayList<(String, String)>): Unit {
        let sb = StringBuilder()
        var lastSt = ""
        for ((t, st) in segs) {
            // 样式变化：先复位再应用，防止粗体等泄漏到后续段/下一行
            if (st != lastSt) {
                sb.append(M_RESET + st)
                lastSt = st
            }
            sb.append(t)
        }
        sb.append(M_RESET)
        this.out.add(trimTrailing(sb.toString()))
    }

    func flushLine(): Unit {
        if (this.segs.size == 0) {
            this.atLineStart = true
            this.pendingStyle = ""
            return
        }
        this.emitLine(this.segs)
        this.segs = ArrayList<(String, String)>()
        this.visible = 0
        this.lastSpace = -1
        this.atLineStart = true
        this.pendingStyle = ""
        this.budget = this.width
    }

    public func finish(): Unit {
        this.flushLine()
    }
}

func trimTrailing(s: String): String {
    let runes = s.toRuneArray()
    var end = runes.size
    while (end > 0) {
        if (runes[end - 1] == Rune(UInt32(0x20))) { end = end - 1 } else { break }
    }
    if (end == runes.size) { return s }
    let out = ArrayList<Rune>()
    for (i in 0..end) { out.add(runes[Int64(i)]) }
    String(out)
}

// 把 markdown 渲染为含 ANSI 的行；prefixWidth 为首行保留前缀（如 "you: "）
public func markdownToLines(md: String, width: Int64, prefixWidth: Int64): ArrayList<String> {
    let r = MdRender(width, prefixWidth)
    // GFM 扩展：表格 / 删除线 / 脚注
    let opts = Options(Options.ENABLE_TABLES | Options.ENABLE_STRIKETHROUGH | Options.ENABLE_FOOTNOTES)
    let p = Parser(md, opts)
    while (let Some(ev) <- p.next()) {
        match (ev) {
            case Event.Start(tag) =>
                match (tag) {
                    case Tag.Heading(level, _, _, _) => r.headingLevel = headingLevelValue(level)
                    case Tag.Strong => r.styles.add(M_BOLD)
                    case Tag.Emphasis => r.styles.add(M_ITALIC)
                    case Tag.Strikethrough => r.styles.add(M_STRIKE)
                    case Tag.CodeBlock(_) => r.inCodeBlock = true
                    case Tag.List(n) =>
                        r.listDepth = r.listDepth + 1
                        r.listNumber = match (n) { case Some(v) => Int64(v); case None => 0 }
                    case Tag.BlockQuote(_) => r.quoteDepth = r.quoteDepth + 1
                    case Tag.Link(_, url, _, _) => r.linkUrl = url.toString()
                    case Tag.ItemMarker => r.listMarkerEmitted = false
                    case _ => ()
                }
            case Event.End(end) =>
                match (end) {
                    case TagEnd.Heading(_) => r.headingLevel = 0; r.flushLine()
                    case TagEnd.Strong => popStyle(r)
                    case TagEnd.Emphasis => popStyle(r)
                    case TagEnd.Strikethrough => popStyle(r)
                    case TagEnd.CodeBlock => r.inCodeBlock = false; r.flushLine()
                    case TagEnd.List(_) =>
                        r.listDepth = if (r.listDepth > 0) { r.listDepth - 1 } else { 0 }
                        r.listNumber = 0
                        r.flushLine()
                    case TagEnd.ItemMarker => r.flushLine()
                    case TagEnd.BlockQuote(_) =>
                        r.quoteDepth = if (r.quoteDepth > 0) { r.quoteDepth - 1 } else { 0 }
                        r.flushLine()
                    case TagEnd.Paragraph => r.flushLine()
                    case TagEnd.Link =>
                        if (r.linkUrl != "") {
                            r.append(" (" + r.linkUrl + ")", style: M_URL)
                            r.linkUrl = ""
                        }
                        r.flushLine()
                    case _ => ()
                }
            case Event.Text(s) => r.append(s.toString())
            case Event.Code(s) => r.append(s.toString(), style: M_CODE)
            case Event.SoftBreak => r.flushLine()
            case Event.HardBreak => r.flushLine()
            case Event.Rule =>
                r.flushLine()
                r.out.add(ruleLine(r.width))
            case _ => ()
        }
    }
    r.finish()
    r.out
}

func popStyle(r: MdRender): Unit {
    if (r.styles.size > 0) { r.styles.remove(r.styles.size - 1..r.styles.size) }
}

func headingLevelValue(l: HeadingLevel): Int64 {
    match (l) {
        case HeadingLevel.H1 => 1
        case HeadingLevel.H2 => 2
        case HeadingLevel.H3 => 3
        case HeadingLevel.H4 => 4
        case HeadingLevel.H5 => 5
        case HeadingLevel.H6 => 6
        case _ => 1
    }
}

func ruleLine(width: Int64): String {
    let sb = StringBuilder()
    for (i in 0..width) { sb.append("─") }
    M_RULE + sb.toString() + M_RESET
}
