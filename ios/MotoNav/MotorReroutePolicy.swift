import Foundation

/// Monotonic, accuracy-aware confirmation and a bounded lease for one recalculation.
struct MotorReroutePolicy {
    static let requestTimeout: TimeInterval = 12
    /// 偏航距离门限。原来是 accuracy*1.6、封顶 80 米：城市里 iPhone 常报 30~50 米精度，
    /// 门限被抬到 48~80 米，再叠加“任意一帧回到门限内就清零”，实际要偏出很远才会重算。
    static func threshold(accuracy: Double) -> Double { max(25, min(60, accuracy * 1.25)) }
    /// 行驶方向明显离开路线时，更小的偏移即可确认（岔路、匝道、辅路这类小角度分叉）。
    static func divergeThreshold(accuracy: Double) -> Double { max(15, min(40, accuracy * 0.8)) }
    /// 航向差（度）：分叉判定 / 逆向判定
    static let divergeAngle = 45.0, reverseAngle = 150.0
    private(set) var pending: UUID?
    private var startedAt = 0.0, nextAllowed = -Double.infinity
    private var firstOff: Double?, lastFix: Double?, count = 0
    private var firstTurn: Double?, turnCount = 0

    mutating func reset() { self = MotorReroutePolicy() }
    private mutating func clearConfirmation() { firstOff = nil; count = 0; firstTurn = nil; turnCount = 0 }

    /// - Parameter headingDelta: 实测航向与路线走向的夹角（0~180 度）；车速低或航向不可信时传 nil。
    mutating func observe(offset: Double, accuracy: Double, now: Double, headingDelta: Double? = nil) -> Bool {
        guard offset.isFinite, offset >= 0, accuracy.isFinite, (0...50).contains(accuracy), now.isFinite else {
            clearConfirmation(); return false
        }
        if let previous = lastFix {
            if now <= previous { return false }
            if now - previous > 3 { clearConfirmation() }
        }
        lastFix = now
        guard pending == nil else { return false }
        let limit = Self.threshold(accuracy: accuracy)
        let beyond = offset > limit
        if beyond {
            if firstOff == nil { firstOff = now }
            count += 1
        } else if offset < limit * 0.6 {
            // 迟滞：只有明确回到路线上才清零；门限附近的抖动不再把已累计的确认次数打回 0。
            firstOff = nil; count = 0
        }
        if let delta = headingDelta, delta.isFinite,
           delta >= Self.reverseAngle || (delta >= Self.divergeAngle && offset > Self.divergeThreshold(accuracy: accuracy)) {
            if firstTurn == nil { firstTurn = now }
            turnCount += 1
        } else {
            firstTurn = nil; turnCount = 0
        }
        guard now >= nextAllowed else { return false }
        let byDistance = beyond && count >= 2 && now - (firstOff ?? now) >= 0.8
        // 航向持续不一致（至少 3 笔、跨 2 秒）：逆向行驶或小角度分叉，不必等偏出整个距离门限。
        let byHeading = turnCount >= 3 && now - (firstTurn ?? now) >= 2
        return byDistance || byHeading
    }
    mutating func begin(now: Double) -> UUID? {
        guard pending == nil, now.isFinite, now >= nextAllowed else { return nil }
        let id = UUID(); pending = id; startedAt = now; clearConfirmation()
        return id
    }
    func expired(now: Double) -> UUID? {
        guard let id = pending, now.isFinite, now - startedAt >= Self.requestTimeout else { return nil }
        return id
    }
    @discardableResult mutating func finish(_ id: UUID, now: Double, success: Bool) -> Bool {
        guard pending == id else { return false }
        pending = nil; clearConfirmation()
        nextAllowed = now + (success ? 6 : 8)
        return true
    }
}
