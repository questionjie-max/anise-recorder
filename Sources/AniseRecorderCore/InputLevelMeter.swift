import Foundation

/// 录音输入电平（第 1 层纯函数）。
///
/// RMS → 0...1 显示值换算 + 静音阈值判定，常量集中定义。
/// dBFS 与 RMS 换算：`db = 20 * log10(rms)`（满幅 1.0 = 0dBFS）。
/// UI 只消费 `InputLevelMeter` 输出，录制链路只上抛 RMS——
/// 两侧都不懂对方的采样实现。
package enum InputLevelMeter {
    /// 静音告警阈值（dBFS）。低于它视为「几乎没有声音」。
    package static let silentThresholdDB: Double = -55

    /// RMS → 显示值（0...1）。 perceptual 近似：dBFS 从 -60 线性映射到
    /// 0dB，再钳制。静音样本（rms ≈ 0）→ 0。
    package static func displayValue(rms: Double) -> Double {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        return normalize(db: db)
    }

    /// dBFS → 0...1（-60dB 及以下 → 0；0dB → 1）。
    package static func normalize(db: Double) -> Double {
        let floor: Double = -60
        guard db > floor else { return 0 }
        return min(1, (db - floor) / (0 - floor))
    }

    /// 是否判定为「近静音」（用于静音告警）。
    package static func isSilent(rms: Double) -> Bool {
        guard rms > 0 else { return true }
        return 20 * log10(rms) < silentThresholdDB
    }

    /// 浮点缓冲区的 RMS（累加平方和 / 帧数后开方）。
    package static func rms(of samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        var sum = 0.0
        for sample in samples {
            let value = Double(sample)
            sum += value * value
        }
        return (sum / Double(samples.count)).squareRoot()
    }
}
