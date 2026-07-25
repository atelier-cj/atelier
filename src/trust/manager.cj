package atelier.trust

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
        this.states[normalize(path)] = state
    }

    public func getTrust(path: String): TrustState {
        match (this.states.get(normalize(path))) {
            case Some(v) => v
            case None => TrustState.Undecided
        }
    }

    public func setSessionTrust(path: String, state: TrustState): Unit {
        this.sessionTrusts[normalize(path)] = state
    }

    public func getEffectiveTrust(path: String): TrustState {
        let p = normalize(path)
        match (this.sessionTrusts.get(p)) {
            case Some(s) => return s
            case None => ()
        }
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
