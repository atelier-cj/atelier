package atelier.agent

import jsonvalue.*
import std.collection.*
import atelier.message.*
import atelier.provider.*

// beforeTool 决策
public enum BeforeToolDecision {
    | Allow
    | Deny(String)
    | Modify(JsonValue)
}

// beforeTurn 决策
public enum TurnDecision {
    | Continue(ChatRequest)
    | ShortCircuit(String)
}

// afterTurn 决策
public class AfterTurnUpdate {
    public let messages: Option<ArrayList<Message>>
    public let shortCircuit: Bool
    public init(messages: Option<ArrayList<Message>>, shortCircuit: Bool) {
        this.messages = messages
        this.shortCircuit = shortCircuit
    }
    public static func none(): AfterTurnUpdate {
        AfterTurnUpdate(None, false)
    }
}

// 每次 run 共享的状态
public class HookState {
    private let values: HashMap<String, JsonValue>
    public init() {
        this.values = HashMap<String, JsonValue>()
    }
    public func set(key: String, value: JsonValue): Unit {
        this.values[key] = value
    }
    public func get(key: String): Option<JsonValue> {
        this.values.get(key)
    }
}
