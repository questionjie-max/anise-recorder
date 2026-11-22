import AVFoundation
import Foundation
import AniseRecorderCore

/// 节流时钟（tap 闭包非 MainActor 隔离，用非隔离小类承载状态；
/// 单写者串行 tap，实际无并发访问）。
private final class ThrottleClock: @unchecked Sendable {
    private var last: Double = 0

    func shouldReport(_ now: Double, interval: Double) -> Bool {
        if last == 0 || now - last >= interval {
            last = now
            return true
        }
        return false
    }

    func reset() {
        last = 0
    }
}

/// 工作台预览输入电平（工作台预览电平）。
///
/// 轻量 `AVAudioEngine` inputTap 采样 → 复用 `InputLevelMeter` 纯函数
/// 换算，0.2s 节流上抛。生命周期由调用方（StudioModel）显式管理：
/// **只在录制工作台可见时运行**，麦克风开关关闭 / 进入编辑器 / 开始
/// 录制即拆除——不做后台常驻（CPU / 耗电纪律）。
///
/// 失败降级（写死）：设备被占用 / 无权限 / 启动抛错 → 无电平条、**零
/// 报错**、界面不卡，开始录制路径完全不受影响。
@MainActor
final class MicrophonePreviewMonitor {
    /// 电平回调（主线程；归一化 0...1）。
    var onLevel: ((Double) -> Void)?

    private var engine = AVAudioEngine()
    private let throttle = ThrottleClock()
    private(set) var isRunning = false

    func start() {
        guard !isRunning else { return }
        // 每次重建 engine：AVAudioEngine 不可重入启动。
        engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return }
        input.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: format
        ) { [weak self] buffer, _ in
            guard let self else { return }
            guard
                self.throttle.shouldReport(
                    Date().timeIntervalSinceReferenceDate,
                    interval: 0.2
                )
            else {
                return
            }
            let rms = InputLevelMeter.rms(
                of: Array(UnsafeBufferPointer(
                    start: buffer.floatChannelData?[0],
                    count: Int(buffer.frameLength)
                ))
            )
            let level = InputLevelMeter.displayValue(rms: rms)
            DispatchQueue.main.async {
                self.onLevel?(level)
            }
        }
        do {
            engine.prepare()
            try engine.start()
            isRunning = true
        } catch {
            // 降级：设备被占用 / 无权限等——拆除并静默，零报错。
            teardown()
        }
    }

    func stop() {
        teardown()
    }

    private func teardown() {
        if engine.inputNode.numberOfInputs > 0 {
            engine.inputNode.removeTap(onBus: 0)
        }
        if engine.isRunning {
            engine.stop()
        }
        isRunning = false
        throttle.reset()
    }
}
