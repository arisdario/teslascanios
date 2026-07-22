import Foundation

/// Per-byte-position statistics across every observed frame for one CAN ID.
struct ByteStat {
    var min: UInt8 = 255
    var max: UInt8 = 0
    var changes = 0          // how many times this byte differed from the previous frame
    var lastValue: UInt8? = nil
    var distinctValues = Set<UInt8>()

    var isStatic: Bool { min == max }
    var range: Int { Int(max) - Int(min) }

    mutating func observe(_ byte: UInt8) {
        min = Swift.min(min, byte)
        max = Swift.max(max, byte)
        if let last = lastValue, last != byte { changes += 1 }
        lastValue = byte
        distinctValues.insert(byte)
    }
}

/// A candidate interpretation of some bits in a frame — what the value *could*
/// be if read as this type at this position. Ranges come from real observed data.
struct FieldCandidate: Identifiable {
    let id = UUID()
    let label: String        // e.g. "Bytes 2-3 Int16 LE"
    let startBit: Int
    let bitLength: Int
    let signed: Bool
    let endian: String       // "intel" | "motorola"
    let observedMin: Double
    let observedMax: Double
    let guess: String        // human hint: "Rolling counter", "Looks static", "Analog-ish", etc.
}

/// Analyzes the frame log for a single CAN ID: byte activity, likely counters,
/// and a generated list of candidate fields with their real observed ranges.
/// This is methodology, not guessing — it shows you where the information is,
/// so you (or Map Unknown Signal) can identify what it means.
struct CANFrameAnalyzer {
    let canID: UInt32
    let frames: [[UInt8]]     // chronological payloads for this ID

    var frameCount: Int { frames.count }
    var dlc: Int { frames.first?.count ?? 0 }

    /// Per-byte stats across all frames.
    func byteStats() -> [ByteStat] {
        guard let width = frames.first?.count else { return [] }
        var stats = Array(repeating: ByteStat(), count: width)
        for frame in frames where frame.count == width {
            for (i, byte) in frame.enumerated() {
                stats[i].observe(byte)
            }
        }
        return stats
    }

    /// A byte position looks like a rolling counter if it steadily increments
    /// (mod some power of two) frame-to-frame. We detect the common case:
    /// mostly-monotonic +1 steps that wrap.
    func counterByteIndices() -> Set<Int> {
        guard let width = frames.first?.count, frames.count > 8 else { return [] }
        var result = Set<Int>()
        for i in 0..<width {
            var incrementSteps = 0
            var total = 0
            var prev: UInt8? = nil
            for frame in frames where frame.count == width {
                if let p = prev {
                    let diff = Int(frame[i]) - Int(p)
                    // +1, or a wrap like 15 -> 0 (diff negative but small magnitude wrap)
                    if diff == 1 || (p == frame[i] &- 1) { incrementSteps += 1 }
                    total += 1
                }
                prev = frame[i]
            }
            // If the strong majority of transitions are +1 steps, call it a counter.
            if total > 0, Double(incrementSteps) / Double(total) > 0.8 {
                result.insert(i)
            }
        }
        return result
    }

    /// Generates candidate multi-byte field interpretations at each byte-aligned
    /// offset, annotated with the real observed value range and a rough guess.
    func candidates() -> [FieldCandidate] {
        let stats = byteStats()
        let counters = counterByteIndices()
        guard dlc > 0 else { return [] }

        var result: [FieldCandidate] = []

        // Single bytes that actually change → worth listing individually.
        for i in 0..<dlc where !stats[i].isStatic {
            if counters.contains(i) {
                result.append(FieldCandidate(
                    label: "Byte \(i)", startBit: i * 8, bitLength: 8, signed: false, endian: "intel",
                    observedMin: Double(stats[i].min), observedMax: Double(stats[i].max),
                    guess: "Rolling counter"))
            }
        }

        // 16-bit fields at each byte offset, both endiannesses, signed + unsigned.
        for i in 0..<(dlc - 1) {
            // Skip if both bytes are static (nothing there).
            if stats[i].isStatic && stats[i+1].isStatic { continue }
            // Skip if either byte is a counter (would pollute the value).
            if counters.contains(i) || counters.contains(i+1) { continue }

            for endian in ["intel", "motorola"] {
                for signed in [false, true] {
                    let (lo, hi) = observedRange(startBit: i * 8, bitLength: 16, signed: signed, endian: endian)
                    let guess = classify(min: lo, max: hi, changing: stats[i].changes + stats[i+1].changes, total: frameCount)
                    result.append(FieldCandidate(
                        label: "Bytes \(i)-\(i+1) \(signed ? "Int16" : "UInt16") \(endian == "intel" ? "LE" : "BE")",
                        startBit: i * 8, bitLength: 16, signed: signed, endian: endian,
                        observedMin: lo, observedMax: hi, guess: guess))
                }
            }
        }
        return result
    }

    private func observedRange(startBit: Int, bitLength: Int, signed: Bool, endian: String) -> (Double, Double) {
        var lo = Double.greatestFiniteMagnitude
        var hi = -Double.greatestFiniteMagnitude
        let decode = CANDecode(startBit: startBit, bitLength: bitLength, signed: signed,
                                scale: 1, offset: 0, note: nil, endianness: endian, enumMap: nil)
        for frame in frames {
            if let v = decode.value(from: frame) {
                lo = Swift.min(lo, v)
                hi = Swift.max(hi, v)
            }
        }
        if lo > hi { return (0, 0) }
        return (lo, hi)
    }

    /// Rough heuristic hint about what a field might be, from its range/activity.
    private func classify(min: Double, max: Double, changing: Int, total: Int) -> String {
        let range = max - min
        if range == 0 { return "Static (no change)" }
        let activity = total > 0 ? Double(changing) / Double(total) : 0
        // Temperature-ish: modest range, plausible °C after a typical scale.
        if min >= -50 && max <= 8000 && range < 4000 && activity > 0.1 {
            return "Analog-ish (sensor/measurement candidate)"
        }
        if activity < 0.02 { return "Rarely changes (status/flag?)" }
        return "Changing multi-byte value"
    }
}
