import AppKit
import SwiftUI

/// 图谱蓝线描滑杆（规范 §5.2 / 纪律 6）：拇指白面 + 图谱蓝描边；
/// 轨道底浅蓝线色、填充图谱蓝。系统 `Slider` 的 `.tint` 只能给蓝色拇指，
/// 拿不到「白面 + 描边」的线描观感，故用 NSSlider 自绘（行为仍走系统：
/// 拖拽、键盘、无障碍全部保留）。
struct StudioSlider: NSViewRepresentable {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var isEnabled = true

    func makeNSView(context: Context) -> StudioSliderView {
        let slider = StudioSliderView()
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        return slider
    }

    func updateNSView(_ slider: StudioSliderView, context: Context) {
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.isEnabled = isEnabled
        if slider.doubleValue != value {
            slider.doubleValue = value
        }
        slider.needsDisplay = true
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(value: $value)
    }

    final class Coordinator {
        @Binding var value: Double

        init(value: Binding<Double>) {
            _value = value
        }

        @objc func changed(_ sender: NSSlider) {
            value = sender.doubleValue
        }
    }
}

/// NSSlider 自绘实现：轨道 4pt 圆角细条，填充随值生长；拇指 13pt 白面圆 +
/// 1.5pt 图谱蓝描边。disabled 整体 38% 透明度（规范状态层口径）。
final class StudioSliderView: NSSlider {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 20)
    }

    override func draw(_ dirtyRect: NSRect) {
        let knobDiameter: CGFloat = 13
        let trackHeight: CGFloat = 4
        let fraction = Self.fraction(
            doubleValue: doubleValue,
            minValue: minValue,
            maxValue: maxValue
        )
        let trackRect = NSRect(
            x: knobDiameter / 2,
            y: (bounds.height - trackHeight) / 2,
            width: max(0, bounds.width - knobDiameter),
            height: trackHeight
        )

        // 轨道底：边框线色（浅蓝线描）
        let trackPath = NSBezierPath(
            roundedRect: trackRect,
            xRadius: trackHeight / 2,
            yRadius: trackHeight / 2
        )
        tokenColor(StudioTheme.separatorLine).setFill()
        trackPath.fill()

        // 填充：图谱蓝，随值生长，裁回圆角轨道
        let fillRect = CGRect(
            x: trackRect.minX,
            y: trackRect.minY,
            width: trackRect.width * fraction,
            height: trackHeight
        )
        trackPath.addClip()
        tokenColor(StudioTheme.accent).setFill()
        NSBezierPath(rect: fillRect).fill()

        // 拇指：白面 + 图谱蓝描边
        let knobRect = NSRect(
            x: trackRect.minX + trackRect.width * fraction - knobDiameter / 2,
            y: (bounds.height - knobDiameter) / 2,
            width: knobDiameter,
            height: knobDiameter
        )
        let knobPath = NSBezierPath(ovalIn: knobRect)
        tokenColor(StudioTheme.textOnScrim).setFill()
        knobPath.fill()
        tokenColor(StudioTheme.accent).setStroke()
        knobPath.lineWidth = 1.5
        knobPath.stroke()
    }

    /// disabled：内容整体 38% 透明度（规范状态层口径，不另发新色）。
    private func tokenColor(_ token: Color) -> NSColor {
        NSColor(token).withAlphaComponent(isEnabled ? 1 : 0.38)
    }

    static func fraction(
        doubleValue: Double,
        minValue: Double,
        maxValue: Double
    ) -> CGFloat {
        guard maxValue > minValue else { return 0 }
        let raw = (doubleValue - minValue) / (maxValue - minValue)
        return CGFloat(min(max(raw, 0), 1))
    }
}
