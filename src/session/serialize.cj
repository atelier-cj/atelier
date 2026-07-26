package atelier.session

import atelier.message.*
import atelier.util.{toJsonString, fromJsonString}
import std.collection.*

public func entriesToJson(entries: ArrayList<Entry>): String {
    toJsonString(entries)
}

public func entriesFromJson(json: String): ArrayList<Entry> {
    try { fromJsonString<ArrayList<Entry>>(json) } catch (_) { ArrayList<Entry>() }
}
