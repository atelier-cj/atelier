package atelier.message

import std.collection.*
import jsonvalue.*

public class ToolCallBlock {
    public let id: String
    public let name: String
    public let args: JsonValue

    public init(id: String, name: String, args: JsonValue) {
        this.id = id
        this.name = name
        this.args = args
    }
}

public enum ContentBlock {
    | TextBlock(String)
    | ToolCall(ToolCallBlock)
    | ToolResultBlock(String, String)
    | ImageBlock(String, String)
}

public class ContentList {
    let _blocks: ArrayList<ContentBlock>

    public init(blocks: ArrayList<ContentBlock>) {
        this._blocks = blocks
    }

    public static func ofText(text: String): ContentList {
        let blocks = ArrayList<ContentBlock>()
        blocks.add(ContentBlock.TextBlock(text))
        return ContentList(blocks)
    }

    public func blocks(): ArrayList<ContentBlock> {
        return this._blocks
    }

    public func toolCalls(): ArrayList<ToolCallBlock> {
        let result = ArrayList<ToolCallBlock>()
        for (block in this._blocks) {
            match (block) {
                case ToolCall(tc) => result.add(tc)
                case _ => ()
            }
        }
        return result
    }
}
