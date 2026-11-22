import AVFoundation
import Foundation

enum AudioWaveform {
    private static let cache = NSCache<NSString, NSArray>()

    static func samples(
        for url: URL,
        count: Int = 180
    ) async -> [CGFloat] {
        let bucketCount = max(1, count)
        let key = "\(url.path)#\(bucketCount)" as NSString
        if let cached = cache.object(forKey: key) as? [CGFloat] {
            return cached
        }
        let samples = await Task.detached(priority: .utility) {
            readSamples(from: url, count: bucketCount)
        }.value
        cache.setObject(samples as NSArray, forKey: key)
        return samples
    }

    private static func readSamples(
        from url: URL,
        count: Int
    ) -> [CGFloat] {
        guard let file = try? AVAudioFile(forReading: url) else {
            return []
        }
        let totalFrames = file.length
        guard totalFrames > 0 else { return [] }
        let format = file.processingFormat
        let frameCapacity = AVAudioFrameCount(
            min(Int64(8_192), max(1, totalFrames / Int64(count)))
        )
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: frameCapacity
            )
        else {
            return []
        }

        var peaks = [Float](repeating: 0, count: count)
        while file.framePosition < totalFrames {
            do {
                try file.read(into: buffer)
            } catch {
                break
            }
            let frameCount = Int(buffer.frameLength)
            guard frameCount > 0 else { break }
            let readStart = file.framePosition - Int64(frameCount)
            let channels = Int(format.channelCount)
            for frame in 0 ..< frameCount {
                let amplitude: Float
                if let channelData = buffer.floatChannelData {
                    var peak: Float = 0
                    for channel in 0 ..< channels {
                        peak = max(
                            peak,
                            abs(channelData[channel][frame])
                        )
                    }
                    amplitude = peak
                } else {
                    amplitude = 0
                }
                let absoluteFrame = readStart + Int64(frame)
                let bucket = min(
                    count - 1,
                    max(
                        0,
                        Int(
                            Double(absoluteFrame)
                                / Double(totalFrames)
                                * Double(count)
                        )
                    )
                )
                peaks[bucket] = max(peaks[bucket], amplitude)
            }
        }

        guard let maximum = peaks.max(), maximum > 0.000_1 else {
            return peaks.map { _ in 0 }
        }
        return peaks.map {
            CGFloat(min(1, max(0, $0 / maximum)))
        }
    }
}
