package atelier.trust

import std.collection.*
import std.sync.*

public enum TrustState {
    | Undecided
    | Trusted
    | Untrusted
}

// 信任管理器：
// - states：目录级持久信任（setTrust，跨会话）；
// - sessionTrusts：无会话上下文的「会话信任」（sessionId="" 的兼容回退，旧 2 参 API 落点）；
// - sessionTrustsBySession：per-session 会话信任（父子并发会话互不干扰）。
// 判定优先级：per-session 覆盖（含沿父目录）→ sessionTrusts（"" 回退）→ states（沿父目录）。
public class TrustManager {
    private let states = HashMap<String, TrustState>()
    private let sessionTrusts = HashMap<String, TrustState>()
    private let sessionTrustsBySession = HashMap<String, HashMap<String, TrustState>>()
    private let lock = Mutex()

    public init() {}

    public func setTrust(path: String, state: TrustState): Unit {
        synchronized(this.lock) { this.states[normalize(path)] = state }
    }

    public func getTrust(path: String): TrustState {
        synchronized(this.lock) {
            match (this.states.get(normalize(path))) {
                case Some(v) => v
                case None => TrustState.Undecided
            }
        }
    }

    // 兼容：无会话 id 的会话信任（等价 sessionId=""；REPL slash 等无会话上下文调用点）
    public func setSessionTrust(path: String, state: TrustState): Unit {
        this.setSessionTrust("", path, state)
    }

    // per-session 会话信任（runtime/ACP 等有会话 id 的调用点；sessionId="" 回落兼容通道）
    public func setSessionTrust(sessionId: String, path: String, state: TrustState): Unit {
        synchronized(this.lock) {
            if (sessionId == "") {
                this.sessionTrusts[normalize(path)] = state
            } else {
                let m = match (this.sessionTrustsBySession.get(sessionId)) {
                    case Some(v) => v
                    case None =>
                        let fresh = HashMap<String, TrustState>()
                        this.sessionTrustsBySession[sessionId] = fresh
                        fresh
                }
                m[normalize(path)] = state
            }
        }
    }

    // 兼容：无会话 id 查询
    public func getEffectiveTrust(path: String): TrustState {
        this.getEffectiveTrust("", path)
    }

    // 判定：sessionId 会话覆盖（含沿父目录继承）→ "" 回退通道 → 目录持久信任（沿父目录继承）
    public func getEffectiveTrust(sessionId: String, path: String): TrustState {
        synchronized(this.lock) {
            this.effectiveLocked(sessionId, path)
        }
    }

    private func effectiveLocked(sessionId: String, path: String): TrustState {
        let p = normalize(path)
        if (sessionId != "") {
            match (this.sessionTrustsBySession.get(sessionId)) {
                case Some(m) =>
                    var cur = p
                    while (cur != "") {
                        match (m.get(cur)) {
                            case Some(TrustState.Trusted) => return TrustState.Trusted
                            case Some(TrustState.Untrusted) => return TrustState.Untrusted
                            case _ => ()
                        }
                        cur = parentDir(cur)
                    }
                case None => ()
            }
        }
        // "" 回退通道（仅精确路径，与旧行为一致）
        match (this.sessionTrusts.get(p)) {
            case Some(s) => return s
            case None => ()
        }
        // 目录持久信任沿父目录
        var current = p
        while (current != "") {
            match (this.states.get(current)) {
                case Some(TrustState.Trusted) => return TrustState.Trusted
                case Some(TrustState.Untrusted) => return TrustState.Untrusted
                case _ => ()
            }
            current = parentDir(current)
        }
        TrustState.Undecided
    }
}

func normalize(path: String): String {
    path
}

func parentDir(path: String): String {
    let parts = path.split("/")
    if (parts.size <= 1) { "" } else {
        let sb = StringBuilder()
        for (i in 0..(parts.size - 1)) {
            if (i > 0) { sb.append("/") }
            sb.append(parts[Int64(i)])
        }
        sb.toString()
    }
}
