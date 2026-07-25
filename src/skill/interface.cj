package atelier.skill

import std.collection.*

public struct Skill {
    public let name: String
    public let description: String
    public let license: Option<String>
    public let compatibility: Option<String>
    public let metadata: HashMap<String, String>
    public let allowedTools: ArrayList<String>
    public let instructions: String
    public let dirPath: String

    public init(name: String, description: String,
        license: Option<String>, compatibility: Option<String>,
        metadata: HashMap<String, String>, allowedTools: ArrayList<String>,
        instructions: String, dirPath: String) {
        this.name = name; this.description = description
        this.license = license; this.compatibility = compatibility
        this.metadata = metadata; this.allowedTools = allowedTools
        this.instructions = instructions; this.dirPath = dirPath
    }
}

public struct SkillMeta {
    public let name: String
    public let description: String
    public init(name: String, description: String) {
        this.name = name; this.description = description
    }
}

public struct SkillContent {
    public let instructions: String
    public let references: ArrayList<String>
    public let scripts: ArrayList<String>
    public init(instructions: String, references: ArrayList<String>, scripts: ArrayList<String>) {
        this.instructions = instructions; this.references = references; this.scripts = scripts
    }
}
