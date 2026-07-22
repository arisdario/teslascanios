import Foundation

/// Correlates an unknown CAN field against the app's KNOWN decoded signals over
/// a window of logged frames. If an unknown byte moves in lockstep with, say,
/// Speed or Battery voltage, that's strong evidence of what it represents —
/// far better than guessing a scale from a couple of static samples.
///
/// This is the honest answer to "what is this unknown byte": instead of asserting
/// a meaning, it measures how tightly the byte tracks each known signal and
/// reports the best matches with a correlation score you can judge.
enum SignalCorrelator {

    struct Match: Identifiable {
        let id = UUID()
        let knownSignalName: String
        let correlation: Double   // -1...1, closer to ±1 = stronger relationship
        let sampleCount: Int
    }

    /// Correlate one candidate field (a byte range within an unknown ID) against
    /// every known decodable signal, using paired samples taken close in time.
    ///
    /// - unknownID: the CAN ID of the unknown message
    /// - startBit/bitLength/endian: how to extract the candidate value
    /// - frameLog: the full timestamped history
    static func correlate(unknownID: UInt32,
                          startBit: Int, bitLength: Int, endian: String,
                          frameLog: [(timestamp: Date, canID: UInt32, bytes: [UInt8])]) -> [Match] {

        let candidateDecode = CANDecode(startBit: startBit, bitLength: bitLength, signed: false,
                                        scale: 1, offset: 0, note: nil, endianness: endian, enumMap: nil)

        // Build a time series of the candidate value.
        var candidateSeries: [(t: Date, v: Double)] = []
        for f in frameLog where f.canID == unknownID {
            if let v = candidateDecode.value(from: f.bytes) {
                candidateSeries.append((f.timestamp, v))
            }
        }
        guard candidateSeries.count >= 5 else { return [] }

        var matches: [Match] = []

        // For each known decodable signal, build its own series and correlate.
        for known in TeslaSignalTable.shared.decodable {
            guard let knownID = known.canID, let decode = known.decode else { continue }
            if knownID == unknownID { continue } // don't correlate a frame with itself

            var knownSeries: [(t: Date, v: Double)] = []
            for f in frameLog where f.canID == knownID {
                if let v = decode.value(from: f.bytes) {
                    knownSeries.append((f.timestamp, v))
                }
            }
            guard knownSeries.count >= 5 else { continue }

            // Pair each candidate sample with the nearest-in-time known sample.
            var xs: [Double] = []
            var ys: [Double] = []
            for c in candidateSeries {
                if let nearest = knownSeries.min(by: {
                    abs($0.t.timeIntervalSince(c.t)) < abs($1.t.timeIntervalSince(c.t))
                }), abs(nearest.t.timeIntervalSince(c.t)) < 0.5 {
                    xs.append(c.v)
                    ys.append(nearest.v)
                }
            }
            guard xs.count >= 5 else { continue }

            if let r = pearson(xs, ys), r.isFinite, abs(r) > 0.5 {
                matches.append(Match(knownSignalName: known.name, correlation: r, sampleCount: xs.count))
            }
        }

        return matches.sorted { abs($0.correlation) > abs($1.correlation) }
    }

    /// Pearson correlation coefficient. Returns nil if either series has no variance.
    private static func pearson(_ x: [Double], _ y: [Double]) -> Double? {
        let n = Double(x.count)
        guard n > 1 else { return nil }
        let mx = x.reduce(0, +) / n
        let my = y.reduce(0, +) / n
        var num = 0.0, dx = 0.0, dy = 0.0
        for i in 0..<x.count {
            let a = x[i] - mx, b = y[i] - my
            num += a * b; dx += a * a; dy += b * b
        }
        guard dx > 0, dy > 0 else { return nil } // no variance = can't correlate
        return num / (dx * dy).squareRoot()
    }
}
