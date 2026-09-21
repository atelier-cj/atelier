package cli

// CLI 共用助手（shared.cj）的单测。

import std.unittest.*
import std.unittest.testmacro.*

@Test
func currentExePath_resolvesNonEmpty() {
    @Expect(currentExePath() != "", true)
}
