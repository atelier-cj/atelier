package atelier.provider

import jsonvalue.*
import std.collection.*
import atelier.message.*

@Test
func chatRequest_extraField() {
    let extra = HashMap<String, JsonValue>()
    extra["reasoning_effort"] = JsonValue.String("high")
    let req = ChatRequest("m", ArrayList<Message>(), 0.7, 100, None, ArrayList(), extra)
    match (req.extra.get("reasoning_effort")) {
        case Some(JsonValue.String(s)) => @Expect(s, "high")
        case _ => @Fail("extra not carried")
    }
}

@Test
func chatRequest_withoutExtra_hasEmptyMap() {
    let req = ChatRequest("m", ArrayList<Message>(), 0.7, 100, None, ArrayList())
    @Expect(req.extra.size, 0)
}
