package atelier.context

public struct CutPoint {
    public let firstKeptIndex: Int64
    public let isSplitTurn: Bool
    public init(firstKeptIndex: Int64, isSplitTurn: Bool) {
        this.firstKeptIndex = firstKeptIndex; this.isSplitTurn = isSplitTurn
    }
}

public func selectCutPoint(totalTokens: Int64, reserveTokens: Int64, keepRecentTokens: Int64): CutPoint {
    if (totalTokens <= reserveTokens) {
        return CutPoint(0, false)
    }
    let surplus = totalTokens - reserveTokens
    let removeTokens = surplus
    let keepFrom = if (removeTokens < keepRecentTokens) { removeTokens } else { keepRecentTokens }
    CutPoint(Int64(keepFrom), false)
}
