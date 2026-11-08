import Foundation

/// What a currency exchange or transfer cost against the market rate (core.ts exchange()), in the source currency's
/// minor units: `total` left the source account, `fee` of it was charged, and the rest became `received`.
public struct FxCost: Equatable, Sendable {
    public var converted: Int64
    /// Units received per unit converted.
    public var rate: Double
    /// What the rate gap cost: the converted amount at market minus what arrived, valued at market. Nil without a rate.
    public var rateCost: Double?
    public var totalCost: Double
    public var costPct: Double

    public init(converted: Int64, rate: Double, rateCost: Double?, totalCost: Double, costPct: Double) {
        self.converted = converted
        self.rate = rate
        self.rateCost = rateCost
        self.totalCost = totalCost
        self.costPct = costPct
    }
}

public func exchange(total: Int64, fee: Int64, received: Int64, marketRate: Double?) -> FxCost {
    let converted = Int64(total.magnitude) - Int64(fee.magnitude)
    let rate = converted > 0 ? Double(received.magnitude) / Double(converted) : 0
    let rateCost = marketRate.flatMap { $0 > 0 ? (Double(converted) * $0 - Double(received.magnitude)) / $0 : nil }
    let totalCost = Double(fee.magnitude) + (rateCost ?? 0)
    return FxCost(converted: converted, rate: rate, rateCost: rateCost, totalCost: totalCost,
                  costPct: total != 0 ? totalCost / Double(total.magnitude) * 100 : 0)
}
