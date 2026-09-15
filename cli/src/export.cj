package cli

import atelier.message.*
import atelier.session.*
import std.collection.*

public func exportJSONL(header: SessionHeader, entries: ArrayList<Entry>): String {
    var r = "{\"version\":" + Int64(header.version).toString()
    r = r + ",\"id\":\"" + header.id + "\""
    r = r + ",\"model\":\"" + header.model + "\""
    r = r + ",\"createdAt\":" + header.createdAt.toString()
    r = r + "}\n"
    for (e in entries) {
        r = r + "{\"id\":\"" + e.id + "\""
        match (e.parentId) {
            case Some(p) => r = r + ",\"parentId\":\"" + p + "\""
            case None => ()
        }
        r = r + ",\"role\":\"" + roleStr(e.message) + "\""
        r = r + ",\"content\":\"" + escapeJSON(textFrom(e.message)) + "\""
        r = r + "}\n"
    }
    r
}

public func exportHTML(header: SessionHeader, entries: ArrayList<Entry>): String {
    var r = "<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\">"
    r = r + "<title>Session: " + header.id + "</title>"
    r = r + "<style>body{font-family:monospace;max-width:800px;margin:auto;padding:20px}"
    r = r + ".user{color:#0066cc}.assistant{color:#009900}.tool{color:#999}.msg{margin:10px 0;padding:10px;border-left:3px solid #ddd}</style>"
    r = r + "</head><body>"
    r = r + "<h1>Session: " + header.id + "</h1>"
    r = r + "<p>Model: " + header.model + " | Provider: " + header.provider + "</p>"
    for (e in entries) {
        let role = roleStr(e.message)
        let cls = match (role) { case "user" => "user"; case "assistant" => "assistant"; case _ => "tool" }
        r = r + "<div class=\"msg " + cls + "\"><strong>" + role + ":</strong> "
        r = r + escapeHTML(textFrom(e.message))
        r = r + "</div>\n"
    }
    r = r + "</body></html>"
    r
}

func roleStr(m: Message): String {
    match (m) {
        case _: UserMessage => "user"
        case _: AssistantMessage => "assistant"
        case _: ToolResultMessage => "tool"
        case _: CompactionMessage => "compaction"
        case _ => "unknown"
    }
}

func textFrom(m: Message): String {
    match (m) {
        case um: UserMessage => contentToText(um.content)
        case am: AssistantMessage => contentToText(am.content)
        case tm: ToolResultMessage => contentToText(tm.content)
        case cm: CompactionMessage => cm.summary
        case _ => ""
    }
}

func contentToText(cl: ContentList): String {
    var r = ""
    for (b in cl.blocks()) {
        match (b) { case ContentBlock.TextBlock(t) => r = r + t; case _ => () }
    }
    r
}

func escapeJSON(s: String): String {
    var r = s.replace("\\", "\\\\")
    r = r.replace("\"", "\\\"")
    r = r.replace("\n", "\\n")
    r = r.replace("\r", "\\r")
    r = r.replace("\t", "\\t")
    r
}

func escapeHTML(s: String): String {
    var r = s.replace("&", "&amp;")
    r = r.replace("<", "&lt;")
    r = r.replace(">", "&gt;")
    r
}
