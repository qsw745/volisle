import Foundation

/// Display-only traffic measurement; never changes the resume offset or disk state.
struct CopyTransferRate: Sendable {
    private struct Sample: Sendable {
        let time: TimeInterval
        let bytes: Int64
    }
    private var samples: [Sample] = []
    private let window: TimeInterval = 3

    mutating func record(bytes: Int64, at time: TimeInterval) {
        guard time.isFinite, bytes >= 0 else { return }
        if let last = samples.last {
            guard time > last.time else { return }
            if bytes < last.bytes { samples.removeAll(keepingCapacity: true) }
        }
        let sample = Sample(time: time, bytes: bytes)
        // File changes bypass UI throttling. Merge reports in 50 ms buckets,
        // preserving the first baseline and the full time window rather than
        // truncating the window when thousands of tiny files finish quickly.
        if samples.count > 1, let last = samples.last,
           floor(last.time * 20) == floor(time * 20) {
            samples[samples.count - 1] = sample
        } else {
            samples.append(sample)
        }
        // Keep the sample just before the window for boundary interpolation.
        while samples.count > 2 && samples[1].time <= time - window { samples.removeFirst() }
    }

    func bytesPerSecond(at time: TimeInterval) -> Double? {
        guard time.isFinite, let first = samples.first, let last = samples.last, time >= last.time else { return nil }
        // A view timer also calls this while a blocking filesystem call reports nothing.
        if time - last.time >= window { return 0 }
        let start = max(first.time, time - window)
        guard time > start, samples.count > 1 else { return nil }
        let index = samples.lastIndex(where: { $0.time <= start }) ?? 0
        let lower = samples[index]
        var bytesAtStart = Double(lower.bytes)
        if index + 1 < samples.count {
            let upper = samples[index + 1]
            bytesAtStart += Double(upper.bytes - lower.bytes) * (start - lower.time) / (upper.time - lower.time)
        }
        return max(0, (Double(last.bytes) - bytesAtStart) / (time - start))
    }
}
