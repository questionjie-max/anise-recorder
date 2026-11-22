import SwiftUI

struct DesktopWallpaperPicker: View {
    @ObservedObject var model: StudioModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: UInt32?

    init(model: StudioModel) {
        self.model = model
        _selectedID = State(
            initialValue: model.desktopWallpaperOptions.first?.id
        )
    }

    private var selectedOption: DesktopWallpaperOption? {
        model.desktopWallpaperOptions.first { $0.id == selectedID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: StudioTheme.space2) {
                    Text("当前系统壁纸")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(StudioTheme.textPrimary)
                    Text(
                        "选择一块显示器当前使用的壁纸，并把当前画面复制为工程背景。"
                    )
                    .font(.callout)
                    .foregroundStyle(StudioTheme.textSecondary)
                }
                Spacer()
                Button {
                    model.dismissDesktopWallpaperPicker()
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.medium))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(SecondaryActionButtonStyle())
                .help("关闭壁纸选择")
                .accessibilityLabel("取消选择系统壁纸")
            }

            ScrollView {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: StudioTheme.space4),
                        GridItem(.flexible(), spacing: StudioTheme.space4)
                    ],
                    spacing: StudioTheme.space4
                ) {
                    ForEach(model.desktopWallpaperOptions) { option in
                        wallpaperCard(option)
                    }
                }
                .padding(.vertical, StudioTheme.space5)
            }
            // P4 防卡死：壁纸解码下沉后台期间的选择器加载态。
            if model.isDesktopWallpaperLoading {
                HStack(spacing: StudioTheme.space3) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(StudioTheme.accent)
                    Text("正在读取系统壁纸…")
                        .font(.callout)
                        .foregroundStyle(StudioTheme.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, StudioTheme.space6)
            }

            Divider()
                .overlay(StudioTheme.separatorLine)

            HStack {
                Text(
                    "这是壁纸的静态快照；动态壁纸不会在成片中播放。"
                )
                .font(.callout)
                .foregroundStyle(StudioTheme.textSecondary)
                Spacer()
                Button {
                    model.dismissDesktopWallpaperPicker()
                    dismiss()
                } label: {
                    Text("取消")
                        .font(.subheadline.weight(.medium))
                        .frame(height: 32)
                        .padding(.horizontal, StudioTheme.space4)
                }
                .buttonStyle(SecondaryActionButtonStyle())
                .keyboardShortcut(.cancelAction)

                Button {
                    guard let selectedOption else { return }
                    model.chooseDesktopWallpaper(selectedOption)
                } label: {
                    Text("使用此壁纸")
                        .font(.subheadline.weight(.semibold))
                        .frame(height: 32)
                        .padding(.horizontal, StudioTheme.space5)
                }
                .buttonStyle(PrimaryActionButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(selectedOption == nil)
            }
            .padding(.top, StudioTheme.space4)
        }
        .padding(StudioTheme.space6)
        .frame(minWidth: 720, minHeight: 520)
        .background(StudioTheme.surfaceCanvas)
        .onAppear {
            if selectedID == nil {
                selectedID = model.desktopWallpaperOptions.first?.id
            }
        }
    }

    private func wallpaperCard(
        _ option: DesktopWallpaperOption
    ) -> some View {
        let selected = selectedID == option.id
        return Button {
            selectedID = option.id
        } label: {
            VStack(alignment: .leading, spacing: StudioTheme.space3) {
                Image(nsImage: option.image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: 154)
                    .clipped()
                    .overlay(alignment: .topTrailing) {
                        if selected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(StudioTheme.textOnAccentContainer)
                                .padding(StudioTheme.space3)
                                .background(StudioTheme.accent)
                                .clipShape(Circle())
                                .padding(StudioTheme.space2)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: StudioTheme.radiusS))

                HStack(spacing: StudioTheme.space3) {
                    VStack(alignment: .leading, spacing: StudioTheme.space1) {
                        Text(option.screenName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(StudioTheme.textPrimary)
                        Text(option.imageURL.lastPathComponent)
                            .font(.callout)
                            .foregroundStyle(StudioTheme.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "display")
                        .font(.system(size: 11))
                        .foregroundStyle(
                            selected ? StudioTheme.accent : StudioTheme.textSecondary
                        )
                }
            }
            .padding(StudioTheme.space3)
            .background(
                selected
                    ? StudioTheme.selectionTint
                    : StudioTheme.surfacePanel
            )
            .overlay(
                RoundedRectangle(cornerRadius: StudioTheme.radiusM)
                    .stroke(
                        selected ? StudioTheme.accent : StudioTheme.separatorLine,
                        lineWidth: selected ? 1.5 : 1
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: StudioTheme.radiusM))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "\(option.screenName) 当前系统壁纸，\(option.imageURL.lastPathComponent)"
        )
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
