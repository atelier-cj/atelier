package atelier.trust

import std.fs.*
import std.collection.*

public enum TrustState {
    | Undecided
    | Trusted
    | Untrusted
}

public class TrustManager {
    private let states = HashMap<String, TrustState>()
    private let sessionTrusts = HashMap<String, TrustState>()

    public init() {}

    public func setTrust(path: String, state: TrustState): Unit {
        // Normalize path
        let p = normalize(path)
        this.states[p] = state
    }

    public func getTrust(path: String): TrustState {
        let p = normalize(path)
        this.states.get(p).getOr(TrustState.Undecided)
    }

    public func setSessionTrust(path: String, state: TrustState): Unit {
        this.sessionTrusts[normalize(path)] = state
    }

    public func getEffectiveTrust(path: String): TrustState {
        let p = normalize(path)
        // Check session trust first
        match (this.sessionTrusts.get(p)) {
            case Some(s) => return s
            case None => ()
        }
        // Walk up the directory tree looking for trust decisions
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
    let p = Path(path).toString()
    if (p.endsWith("/") && p.size > 1) { p.substring(0, p.size - 1) } else { p }
}

func parentDir(path: String): String {
    let p = Path(path)
    let parent = p.parent
    parent.toString()
}
