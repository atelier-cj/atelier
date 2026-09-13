package atelier.session

import atelier.message.*
import atelier.util.{toJsonString, fromJsonString}
import std.collection.*

public func entriesToJson(entries: ArrayList<Entry>): String {
    toJsonString(entries)
}

public func entriesFromJson(json: String): ArrayList<Entry> {
    // 反序列化失败即「整份会话历史归零」，与「本来就是空会话」不可区分——必须留痕
    try { fromJsonString<ArrayList<Entry>>(json) } catch (e: Exception) {
        eprintln("[atelier] session entries deserialize failed (history lost): ${e.toString()}")
        ArrayList<Entry>()
    }
}
