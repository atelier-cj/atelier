package atelier.a2a

import std.time.*

// A2A 适配层的公共小工具。
// 协议要求 ISO 8601 UTC、毫秒精度、以 Z 结尾（TCK DM-SERIAL-003）。手工拼 T/Z 与毫秒位：
// 格式串里的字面量转义规则不可靠（'T' 原样输出，而裸 Z 会被当时区占位符渲染成 GMT+0）。
// 定宽（毫秒补零）保证字符串字典序即时间序，可直接用于按时间排序（tasks/list）。
func nowIso8601(): String {
    let dt = DateTime.nowUTC()
    let ms = dt.nanosecond / 1_000_000
    "${dt.format("yyyy-MM-dd")}T${dt.format("HH:mm:ss")}.${pad3(ms)}Z"
}

private func pad3(v: Int64): String {
    if (v < 10) {
        return "00${v}"
    }
    if (v < 100) {
        return "0${v}"
    }
    "${v}"
}
