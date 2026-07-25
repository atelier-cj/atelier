package atelier.util

import stdx.encoding.json.stream.*
import std.io.ByteBuffer
import std.fs.{File, Path}

public func toJsonString<T>(obj: T): String where T <: JsonSerializable {
    let buf = ByteBuffer()
    let w = JsonWriter(buf)
    w.writeValue(obj)
    w.flush()
    String.fromUtf8(buf.bytes())
}

public func toPrettyJsonString<T>(obj: T): String where T <: JsonSerializable {
    let buf = ByteBuffer()
    let w = JsonWriter(buf)
    w.writeConfig = WriteConfig.pretty
    w.writeValue(obj)
    w.flush()
    String.fromUtf8(buf.bytes())
}

public func fromJsonString<T>(json: String): T where T <: JsonDeserializable<T> {
    let buf = ByteBuffer(json.toArray())
    let r = JsonReader(buf)
    T.fromJson(r)
}
