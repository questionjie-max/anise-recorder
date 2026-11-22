import SwiftUI

enum InspectorSection: String, CaseIterable, Hashable {
    case canvas
    case canvasLayout
    case canvasRedaction
    case cameraComposition
    case cameraPresets
    case cameraPosition
    case cameraAppearance
    case cameraChromaKey
    case cameraFace
    case clip
    case markers
    case cursor
    case audio
    case zoom
    case smartCutVoice
    case smartCutFiller
    case captionContent
    case captionStyle
    case captionSecondary
    case captionGlossary
    case captionChapters
    case overlay
}

struct InspectorDestination: Equatable {
    let tab: EditorTab
    let section: InspectorSection
}

struct InspectorScrollRequest: Equatable {
    let id = UUID()
    let section: InspectorSection?
}

enum TimelineTrack: String, CaseIterable, Identifiable {
    case video
    case camera
    case zoom
    case audio
    case overlay

    var id: String { rawValue }

    var title: String {
        switch self {
        case .video:
            return "视频"
        case .camera:
            return "摄像头"
        case .zoom:
            return "缩放"
        case .audio:
            return "声音"
        case .overlay:
            return "叠加"
        }
    }

    var inspectorDestination: InspectorDestination {
        switch self {
        case .video:
            return InspectorDestination(tab: .edit, section: .clip)
        case .camera:
            return InspectorDestination(tab: .camera, section: .cameraComposition)
        case .zoom:
            return InspectorDestination(tab: .edit, section: .zoom)
        case .audio:
            return InspectorDestination(tab: .edit, section: .audio)
        case .overlay:
            return InspectorDestination(tab: .canvas, section: .overlay)
        }
    }
}

struct InspectorDisclosureSection<Content: View>: View {
    let title: String
    let icon: String
    let summary: String?
    @Binding var isExpanded: Bool
    let content: Content

    init(
        title: String,
        icon: String,
        summary: String? = nil,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.icon = icon
        self.summary = summary
        _isExpanded = isExpanded
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: StudioTheme.space2) {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(StudioTheme.accent)
                        .frame(width: 16)
                    Text(title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(StudioTheme.textPrimary)
                    Spacer(minLength: StudioTheme.space2)
                    if let summary, !isExpanded {
                        Text(summary)
                            .font(.callout)
                            .foregroundStyle(StudioTheme.textSecondary)
                            .lineLimit(1)
                    }
                    Image(
                        systemName: isExpanded
                            ? "chevron.down"
                            : "chevron.right"
                    )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(StudioTheme.textTertiary)
                }
                .contentShape(Rectangle())
                .frame(minHeight: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                "\(title)，\(isExpanded ? "已展开" : "已收起")"
            )
            .accessibilityHint("按下以\(isExpanded ? "收起" : "展开")")

            if isExpanded {
                content
                    .padding(.top, StudioTheme.space3)
            }
        }
    }
}
