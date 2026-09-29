package atelier.util

import std.fs.*

func writeGitignore(dir: String, rules: String): Unit {
    File.writeTo(dir + "/.gitignore", rules.toArray())
}

func cleanDir(dir: String): Unit {
    try { remove(Path(dir), recursive: true) } catch (_) { () }
}

// 写入规则到临时目录并加载，返回 matcher（用完即清理）
func matcherWithRules(rules: String): GitIgnoreMatcher {
    let dir = Directory.createTemp(Path("/tmp")).toString()
    writeGitignore(dir, rules)
    let m = GitIgnoreMatcher(dir)
    cleanDir(dir)
    m
}

@Test
func gitignore_emptyMatcherIgnoresNothing() {
    let m = GitIgnoreMatcher()
    @Expect(m.isIgnored("foo.txt"), false)
    @Expect(m.isIgnored("build/"), false)
    @Expect(m.isIgnored("a/b/c.log"), false)
}

@Test
func gitignore_missingGitignoreIgnoresNothing() {
    let dir = Directory.createTemp(Path("/tmp")).toString()
    let m = GitIgnoreMatcher(dir)
    @Expect(m.isIgnored("foo.txt"), false)
    @Expect(m.isIgnored("anything"), false)
    cleanDir(dir)
}

@Test
func gitignore_exactMatch() {
    let m = matcherWithRules("foo.txt\n")
    @Expect(m.isIgnored("foo.txt"), true)
    @Expect(m.isIgnored("a/foo.txt"), true)
    @Expect(m.isIgnored("foo.txt2"), false)
    @Expect(m.isIgnored("FOO.txt"), false)
}

@Test
func gitignore_starWildcard() {
    let m = matcherWithRules("*.log\n")
    @Expect(m.isIgnored("a.log"), true)
    @Expect(m.isIgnored("dir/b.log"), true)
    @Expect(m.isIgnored("a.txt"), false)
    @Expect(m.isIgnored("log"), false)
}

@Test
func gitignore_questionWildcard() {
    let m = matcherWithRules("file?.txt\n")
    @Expect(m.isIgnored("file1.txt"), true)
    @Expect(m.isIgnored("fileA.txt"), true)
    @Expect(m.isIgnored("file12.txt"), false)
}

@Test
func gitignore_dirRule() {
    let m = matcherWithRules("build/\n")
    @Expect(m.isIgnored("build/"), true)
    @Expect(m.isIgnored("build"), false)
    @Expect(m.isIgnored("build/x/y"), false)
}

@Test
func gitignore_anchoredRule() {
    let m = matcherWithRules("/foo.txt\n")
    @Expect(m.isIgnored("foo.txt"), true)
    @Expect(m.isIgnored("a/foo.txt"), false)
}

@Test
func gitignore_negateRule() {
    let m = matcherWithRules("*.log\n!keep.log\n")
    @Expect(m.isIgnored("a.log"), true)
    @Expect(m.isIgnored("keep.log"), false)
}

@Test
func gitignore_commentAndBlankLines() {
    let m = matcherWithRules("# comment\n\nfoo.txt\n")
    @Expect(m.isIgnored("foo.txt"), true)
    @Expect(m.isIgnored("comment"), false)
    @Expect(m.isIgnored("# comment"), false)
}

@Test
func gitignore_loadFromRealFile() {
    let dir = Directory.createTemp(Path("/tmp")).toString()
    writeGitignore(dir, "*.tmp\nsecret/\n!keep.tmp\n")
    let m = GitIgnoreMatcher()
    @Expect(m.isIgnored("x.tmp"), false)
    m.loadFrom(dir)
    @Expect(m.isIgnored("x.tmp"), true)
    @Expect(m.isIgnored("keep.tmp"), false)
    @Expect(m.isIgnored("secret/"), true)
    cleanDir(dir)
}
