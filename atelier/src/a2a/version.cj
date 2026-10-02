package atelier.a2a

import cjpminfo.*

/**
 * 产品版本号：编译期由 cjpminfo 从 cjpm.toml 的 package.version 读取。
 *
 * 刻意放在**核心库**而不是 cli：cjpm ws 只把产品版本物化到参与发布的成员，
 * cli / server 不在其中 —— 版本常量若定义在 cli，发版后卡片会报出与产品脱节的旧版本。
 */
public let AtelierVersion: String = @ModuleVer("0.0.0")
