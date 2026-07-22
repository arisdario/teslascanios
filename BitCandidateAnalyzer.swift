import Foundation

/// A candidate bit window that might encode the signal we're calibrating.
struct BitCandidate: Codable {
    let startBit: Int
    let bitLength: Int
    let signed: Bool
    let baselineMin: Double
    let baselineMax: Double
    let activeMin: Double
    let activeMax: Double
    /// Higher = more likely to be the real signal: rewards a window that stayed
    /// flat at baseline and moved distinctly during the labeled action.
    let score: Double
}

/// Diffs two recordings of the same CAN ID (a quiet "baseline" period and an
/// "active" period where you performed a known action, e.g. pressing the brake)
/// to find which bit windows actually changed. This is the standard manual
/// technique CAN reverse-engineers use — we're just automating the bookkeeping.
/// Claude's job afterward is to pick among the surviving candidates and reason
/// about physical scale, not to find them from nothing.
enum BitCandidateAnalyzer {

    static func candidates(
        baseline: [[UInt8]],
        active: [[UInt8]],
        dlc: Int
    ) -> [BitCandidate] {
        guard !baseline.isEmpty, !active.isEmpty else { return [] }

        var results: [BitCandidate] = []
        let widths = [8, 16, 24, 32]
        for width in widths {
            var start = 0
            while start + width <= dlc * 8 {
                for signed in [false, true] {
                    let decode = CANDecode(startBit: start, bitLength: width, signed: signed, scale: 1, offset: 0, note: nil)
                    let baseVals = baseline.compactMap { decode.value(from: $0) }
                    let activeVals = active.compactMap { decode.value(from: $0) }
                    guard baseVals.count > 1, activeVals.count > 1 else { continue }

                    let bMin = baseVals.min()!, bMax = baseVals.max()!
                    let aMin = activeVals.min()!, aMax = activeVals.max()!
                    let baselineSpread = bMax - bMin
                    let activeSpread = aMax - aMin
                    let shift = abs(((aMax + aMin) / 2) - ((bMax + bMin) / 2))

                    // Reward: quiet at baseline, moved during the action.
                    let score = shift + activeSpread - baselineSpread * 2
                    guard score > 0 else { continue }

                    results.append(BitCandidate(
                        startBit: start, bitLength: width, signed: signed,
                        baselineMin: bMin, baselineMax: bMax,
                        activeMin: aMin, activeMax: aMax,
                        score: score
                    ))
                }
                start += 8 // byte-aligned candidates only — covers the overwhelming majority of Tesla signals
            }
        }
        return results.sorted { $0.score > $1.score }.prefix(8).map { $0 }
    }
}
