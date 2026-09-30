package atelier.tool.builtin

import std.collection.*
import std.env.getProcessId
import std.fs.*

// 内置工具的路径与通配匹配：这两处此前都会产生「假失败」——
// 绝对路径被拼在 workDir 后面、目录前缀带通配的 glob 直接报"搜索路径不存在"。
// 假失败比真失败更贵：模型会把回合花在换写法重试上。

@Test
func paths_absoluteStaysAbsolute() {
    @Expect(resolveToolPath("/work", "/etc/hosts"), "/etc/hosts")
    @Expect(resolveToolPath("/work/", "/tmp/x"), "/tmp/x")
}

@Test
func paths_relativeJoinsWorkDir() {
    @Expect(resolveToolPath("/work", "src/a.ts"), "/work/src/a.ts")
    @Expect(resolveToolPath("/work/", "src/a.ts"), "/work/src/a.ts")
    // 无 workDir（库模式）时原样返回
    @Expect(resolveToolPath("", "src/a.ts"), "src/a.ts")
    @Expect(resolveToolPath("/work", ""), "")
}

@Test
func glob_doubleStarSpansDirectories() {
    @Expect(globMatchPath("**/*.ts", "a.ts"), true)
    @Expect(globMatchPath("**/*.ts", "src/a.ts"), true)
    @Expect(globMatchPath("**/*.ts", "src/x/y/a.ts"), true)
    @Expect(globMatchPath("**/*.ts", "src/a.md"), false)
}

@Test
func glob_directoryPrefixWithWildcard() {
    // `src/**/*`：此前会被当成"目录 <workDir>/src/**"去 exists() → 假失败
    @Expect(globMatchPath("src/**/*", "src/a.ts"), true)
    @Expect(globMatchPath("src/**/*", "src/x/y.ts"), true)
    @Expect(globMatchPath("src/**/*", "other/a.ts"), false)
    @Expect(globMatchPath("mods/**/*", "mods/m1/data.json"), true)
}

@Test
func glob_singleStarStaysInSegment() {
    @Expect(globMatchPath("*.ts", "a.ts"), true)
    @Expect(globMatchPath("*.ts", "src/a.ts"), false)
    @Expect(globMatchPath("src/*.ts", "src/a.ts"), true)
    @Expect(globMatchPath("src/*.ts", "src/x/a.ts"), false)
}

@Test
func glob_bracesAndQuestionMark() {
    @Expect(globMatchPath("**/*.{ts,md}", "src/a.md"), true)
    @Expect(globMatchPath("**/*.{ts,md}", "src/a.ts"), true)
    @Expect(globMatchPath("**/*.{ts,md}", "src/a.json"), false)
    @Expect(globMatchPath("a?.ts", "ab.ts"), true)
    @Expect(globMatchPath("a?.ts", "abc.ts"), false)
}

@Test
func glob_starDoesNotMatchSlashInSegment() {
    @Expect(globMatchPath("src/*", "src/a.ts"), true)
    @Expect(globMatchPath("src/*", "src/x/a.ts"), false)
}

@Test
func paths_ensureParentDirCreatesNested() {
    // 用进程内唯一的目录名，避免与并发用例互相踩（仓颉的 Directory 没有递归删除）
    let root = "/tmp/atelier-paths-test-" + getProcessId().toString()
    let base = root + "/one/two"
    @Expect(exists(base), false)
    ensureParentDir(base + "/file.txt")
    @Expect(exists(base), true)
    // 已存在时不报错（幂等）
    ensureParentDir(base + "/file.txt")
    @Expect(exists(base), true)
    // 清理交给系统（/tmp 下的唯一目录，无需在本用例里做递归删除）
}

@Test
func paths_ensureParentDirIgnoresTopLevel() {
    // 顶层文件（无目录部分）不该尝试建目录
    ensureParentDir("file.txt")
    @Expect(exists("file.txt"), false)
}
