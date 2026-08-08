package atelier.server

import jsonvalue.*
import std.collection.*
import stdx.serialization.serialization.*
import atelier.provider.*

func makeTomlProvider(extra: DataModel): TomlProvider {
    let tp = TomlProvider()
    tp.name = "test"
    tp.providerType = "openai"
    tp.baseURL = "http://x"
    tp.apiKey = "key"
    tp.extra = extra
    tp
}

@Test
func toProviderConfig_extraStringMap() {
    // TOML: extra = { reasoning_effort = "high" }
    let extra = DataModelStruct()
        .add(field<String>("reasoning_effort", "high"))
    let tp = makeTomlProvider(extra)
    let cfg = toProviderConfig(tp)
    match (cfg.extra.get("reasoning_effort")) {
        case Some(JsonValue.String(s)) => @Expect(s, "high")
        case _ => @Fail("extra not converted")
    }
}

@Test
func toProviderConfig_extraNestedAndNumber() {
    // TOML: extra = { top_p = 0.9, response_format = { type = "json" } }
    let nested = DataModelStruct()
        .add(field<String>("type", "json"))
    let extra = DataModelStruct()
        .add(field<Float64>("top_p", 0.9))
        .add(Field("response_format", nested))
    let tp = makeTomlProvider(extra)
    let cfg = toProviderConfig(tp)
    match (cfg.extra.get("top_p")) {
        case Some(JsonValue.Number(n)) => @Expect(n, 0.9)
        case _ => @Fail("number not preserved")
    }
    match (cfg.extra.get("response_format")) {
        case Some(JsonValue.Map(m)) =>
            match (m.get("type")) {
                case Some(JsonValue.String(s)) => @Expect(s, "json")
                case _ => @Fail("nested value missing")
            }
        case _ => @Fail("nested object not converted")
    }
}

@Test
func toProviderConfig_missingExtra_returnsEmpty() {
    // 无 extra 字段 → DataModelNull → 空 map
    let tp = makeTomlProvider(DataModelNull())
    let cfg = toProviderConfig(tp)
    @Expect(cfg.extra.size, 0)
}

@Test
func toProviderConfig_fieldsCarried() {
    let tp = makeTomlProvider(DataModelNull())
    let cfg = toProviderConfig(tp)
    @Expect(cfg.`type`, "openai")
    @Expect(cfg.name, "test")
    @Expect(cfg.baseURL, "http://x")
    @Expect(cfg.apiKey, "key")
}

@Test
func tomlProvider_serializeDeserializeRoundTrip() {
    let extra = DataModelStruct()
        .add(field<Int64>("max_tokens", 100))
        .add(field<String>("reasoning_effort", "high"))
    let tp = makeTomlProvider(extra)

    // serialize → deserialize round-trip
    let dm = tp.serialize()
    let tp2 = TomlProvider.deserialize(dm)
    match (tp2.extra) {
        case dms: DataModelStruct =>
            match (dms.get("max_tokens")) {
                case di: DataModelInt => @Expect(di.getValue(), 100)
                case _ => @Fail("max_tokens lost")
            }
            match (dms.get("reasoning_effort")) {
                case ds: DataModelString => @Expect(ds.getValue(), "high")
                case _ => @Fail("reasoning_effort lost")
            }
        case _ => @Fail("extra not preserved as DataModelStruct")
    }
}
