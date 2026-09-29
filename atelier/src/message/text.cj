package atelier.message

// 从 ContentList 提取纯文本（TextBlock 拼接；工具调用/图片等块忽略）
public func textFromContent(cl: ContentList): String {
    var r = ""
    for (b in cl.blocks()) {
        match (b) { case ContentBlock.TextBlock(t) => r = r + t; case _ => () }
    }
    r
}

// 消息整体纯文本（CompactionMessage 取其摘要，其余取内容文本）
public func textOfMsg(m: Message): String {
    let cl = match (m) {
        case um: UserMessage => um.content
        case am: AssistantMessage => am.content
        case tm: ToolResultMessage => tm.content
        case cm: CompactionMessage => ContentList.ofText(cm.summary)
        case _ => ContentList.ofText("")
    }
    textFromContent(cl)
}
