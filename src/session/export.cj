package atelier.session

import atelier.message.*
import atelier.util.toJsonString
import std.collection.*

public func exportToJsonl(msgs: ArrayList<Message>): String {
    let sb = StringBuilder()
    for (m in msgs) {
        match (m) {
            case um: UserMessage =>
                sb.append("{\"role\":\"user\",\"content\":\"" + escapeHtml(textFrom(um.content)) + "\"}\n")
            case am: AssistantMessage =>
                sb.append("{\"role\":\"assistant\",\"content\":\"" + escapeHtml(textFrom(am.content)) + "\"}\n")
            case tm: ToolResultMessage =>
                sb.append("{\"role\":\"tool\",\"content\":\"" + escapeHtml(textFrom(tm.content)) + "\"}\n")
            case _ => ()
        }
    }
    sb.toString()
}

public func exportToHtml(msgs: ArrayList<Message>): String {
    let sb = StringBuilder()
    sb.append("<!DOCTYPE html><html lang=\"zh-CN\"><head><meta charset=\"UTF-8\"><title>Session Export</title>")
    sb.append("<style>body{max-width:720px;margin:40px auto;font:16px/1.6 sans-serif}.msg{margin:16px 0;padding:12px 16px;border-radius:8px}.user{background:#e8f4fd}.assistant{background:#f0f0f0}.tool{background:#fff3e0;font-size:14px;color:#666}</style>")
    sb.append("</head><body>")
    for (m in msgs) {
        match (m) {
            case um: UserMessage =>
                sb.append("<div class=\"msg user\"><strong>You:</strong><br>" + escapeHtml(textFrom(um.content)) + "</div>\n")
            case am: AssistantMessage =>
                sb.append("<div class=\"msg assistant\"><strong>Assistant:</strong><br>" + escapeHtml(textFrom(am.content)) + "</div>\n")
            case tm: ToolResultMessage =>
                sb.append("<div class=\"msg tool\"><strong>Tool (" + escapeHtml(tm.toolName) + "):</strong><br>" + escapeHtml(textFrom(tm.content)) + "</div>\n")
            case _ => ()
        }
    }
    sb.append("</body></html>")
    sb.toString()
}

func textFrom(cl: ContentList): String {
    let sb2 = StringBuilder()
    for (b in cl.blocks()) {
        match (b) { case ContentBlock.TextBlock(t) => sb2.append(t); case _ => () }
    }
    sb2.toString()
}

func escapeHtml(s: String): String {
    var r = s.replace("&", "&amp;")
    r = r.replace("<", "&lt;")
    r = r.replace(">", "&gt;")
    r = r.replace("\"", "&quot;")
    r
}
