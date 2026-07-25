package atelier.message

@Test
func messageRole_values() {
    match (MessageRole.User) {
        case MessageRole.User => ()
        case _ => @Fail("expected User")
    }
    match (MessageRole.Assistant) {
        case MessageRole.Assistant => ()
        case _ => @Fail("expected Assistant")
    }
    match (MessageRole.ToolResult) {
        case MessageRole.ToolResult => ()
        case _ => @Fail("expected ToolResult")
    }
    match (MessageRole.Compaction) {
        case MessageRole.Compaction => ()
        case _ => @Fail("expected Compaction")
    }
}

@Test
func stopReason_values() {
    match (StopReason.EndTurn) {
        case StopReason.EndTurn => ()
        case _ => @Fail("expected EndTurn")
    }
    match (StopReason.ToolUse) {
        case StopReason.ToolUse => ()
        case _ => @Fail("expected ToolUse")
    }
    match (StopReason.Length) {
        case StopReason.Length => ()
        case _ => @Fail("expected Length")
    }
    match (StopReason.Error) {
        case StopReason.Error => ()
        case _ => @Fail("expected Error")
    }
    match (StopReason.Aborted) {
        case StopReason.Aborted => ()
        case _ => @Fail("expected Aborted")
    }
}
