package atelier.a2a

import std.time.*

// A2A 适配层的公共小工具。协议要求 ISO 8601 UTC、以 Z 结尾（TCK DM-SERIAL-003）。
// 用 OOOO（ISO 8601 时区偏移，UTC 渲染为 Z）+ SSS：输出定宽（纳秒位补零），
// 因此字符串字典序即时间序，可直接用于按时间排序（tasks/list）。
func nowIso8601(): String {
    DateTime.nowUTC().format("yyyy-MM-ddTHH:mm:ss.SSSOOOO")
}
