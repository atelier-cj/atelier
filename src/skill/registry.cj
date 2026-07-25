package atelier.skill

import std.collection.*

public class SkillRegistry {
    private let skills = HashMap<String, Skill>()

    public init() {}

    public func register(skill: Skill): Unit {
        this.skills[skill.name] = skill
    }

    public func get(name: String): Option<Skill> {
        this.skills.get(name)
    }

    public func list(): ArrayList<Skill> {
        let result = ArrayList<Skill>()
        for ((_, s) in this.skills) { result.add(s) }
        result
    }

    public func has(name: String): Bool {
        this.skills.contains(name)
    }

    public func remove(name: String): Unit {
        this.skills.remove(name)
    }

    public func loadDirectory(dir: String): Unit {
        let loader = SkillLoader()
        let loaded = loader.loadDir(dir)
        for (skill in loaded) { this.register(skill) }
    }
}
