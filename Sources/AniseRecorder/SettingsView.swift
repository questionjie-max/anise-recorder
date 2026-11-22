import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: StudioModel

    var body: some View {
        Form {
            Section("录制") {
                Toggle(
                    "Esc 停止前需确认",
                    isOn: Binding(
                        get: { model.stopRequiresConfirmation },
                        set: { model.setStopRequiresConfirmation($0) }
                    )
                )
            }

            Section("工程管理") {
                Picker(
                    "Delete 键默认动作",
                    selection: Binding(
                        get: { model.defaultProjectRemovalAction },
                        set: { model.setDefaultProjectRemovalAction($0) }
                    )
                ) {
                    ForEach(ProjectRemovalAction.allCases) { action in
                        Text(action.title).tag(action)
                    }
                }

                Toggle(
                    "显示已移除工程",
                    isOn: Binding(
                        get: { model.showHiddenProjects },
                        set: { model.setShowHiddenProjects($0) }
                    )
                )
            }

            Section("归档") {
                LabeledContent("归档目录") {
                    Text(ProjectStore.archiveURL.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                HStack(spacing: StudioTheme.space4) {
                    Button("在访达中显示") {
                        model.revealArchiveFolder()
                    }
                    Button("导入归档工程…") {
                        model.chooseProjectToImport()
                    }
                    .disabled(!model.canManageProjects)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Text(AppVersion.detailedDescription())
                    .font(.subheadline)
                    .foregroundStyle(StudioTheme.textTertiary)
                    .padding(.horizontal, StudioTheme.space5)
                    .padding(.bottom, StudioTheme.space3)
            }
            .background(StudioTheme.surfaceCanvas)
        }
        .formStyle(.grouped)
        .frame(width: 500)
        // §9.3：系统 Form 不自绘行，仅把滚动底换成 surfaceCanvas（分组行容器仍是系统材质）
        .scrollContentBackground(.hidden)
        .background(StudioTheme.surfaceCanvas)
        .padding(.vertical, StudioTheme.space3)
        .preferredColorScheme(.light)
    }
}
