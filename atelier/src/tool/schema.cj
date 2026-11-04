package atelier.tool

import std.collection.*
import jsonvalue.*

public class SchemaBuilder {
    private let properties = HashMap<String, JsonValue>()
    private let requiredList = ArrayList<String>()

    public init() {}

    public func addString(name: String, desc: String, required!: Bool = false): SchemaBuilder {
        addField(name, "string", desc, required)
        this
    }

    public func addInteger(name: String, desc: String, required!: Bool = false): SchemaBuilder {
        addField(name, "integer", desc, required)
        this
    }

    public func addBoolean(name: String, desc: String, required!: Bool = false): SchemaBuilder {
        addField(name, "boolean", desc, required)
        this
    }

    public func addEnum(name: String, desc: String, values: ArrayList<String>, required!: Bool = false): SchemaBuilder {
        let field = HashMap<String, JsonValue>()
        field.add("type", JsonValue.String("string"))
        field.add("description", JsonValue.String(desc))
        let enumArr = ArrayList<JsonValue>()
        for (v in values) { enumArr.add(JsonValue.String(v)) }
        field.add("enum", JsonValue.Array(enumArr))
        this.properties.add(name, JsonValue.Map(field))
        if (required) { this.requiredList.add(name) }
        this
    }

    private func addField(name: String, typ: String, desc: String, required: Bool) {
        let field = HashMap<String, JsonValue>()
        field.add("type", JsonValue.String(typ))
        field.add("description", JsonValue.String(desc))
        this.properties.add(name, JsonValue.Map(field))
        if (required) { this.requiredList.add(name) }
    }

    public func build(): JsonValue {
        let obj = HashMap<String, JsonValue>()
        obj.add("type", JsonValue.String("object"))
        obj.add("properties", JsonValue.Map(this.properties))
        if (!this.requiredList.isEmpty()) {
            let req = ArrayList<JsonValue>()
            for (r in this.requiredList) { req.add(JsonValue.String(r)) }
            obj.add("required", JsonValue.Array(req))
        }
        JsonValue.Map(obj)
    }

    public static func string(name: String, desc: String, required!: Bool = false): JsonValue {
        SchemaBuilder().addString(name, desc, required: required).build()
    }

    public static func integer(name: String, desc: String, required!: Bool = false): JsonValue {
        SchemaBuilder().addInteger(name, desc, required: required).build()
    }
}
