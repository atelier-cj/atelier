package atelier.agent

import jsonvalue.*
import std.collection.*
import atelier.message.*
import atelier.provider.*

@Test
func beforeToolDecision_variants() {
    let allow = BeforeToolDecision.Allow
    @Expect(allow is BeforeToolDecision, true)
    let deny = BeforeToolDecision.Deny("not allowed")
    @Expect(deny is BeforeToolDecision, true)
    let modify = BeforeToolDecision.Modify(JsonValue.Map(HashMap<String, JsonValue>()))
    @Expect(modify is BeforeToolDecision, true)
}

@Test
func turnDecision_variants() {
    let req = ChatRequest("m", ArrayList<Message>(), 0.7, 100, None, ArrayList())
    let cont = TurnDecision.Continue(req)
    @Expect(cont is TurnDecision, true)
    let sc = TurnDecision.ShortCircuit("stop")
    @Expect(sc is TurnDecision, true)
}

@Test
func hookState_getSet() {
    let st = HookState()
    st.set("cost", JsonValue.Number(1.5))
    match (st.get("cost")) {
        case Some(JsonValue.Number(n)) => @Expect(n, 1.5)
        case _ => @Fail("expected number")
    }
    match (st.get("missing")) {
        case None => ()
        case _ => @Fail("expected None for missing key")
    }
}
