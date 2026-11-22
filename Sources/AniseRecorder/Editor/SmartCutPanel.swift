import AniseRecorderCore
import SwiftUI

/// 精剪页：扫描停顿 / 气口候选，逐条审阅后原子应用。
/// 候选只是建议，不在打开工程时偷偷分析，也不静默应用（路线图第 3 节）。
struct SmartCutPanel: View {
    @ObservedObject var model: StudioModel
    let project: StudioProject
    @Binding var expandedSections: Set<InspectorSection>

    var body: some View {
        VStack(alignment: .leading, spacing: StudioTheme.space4) {
            sectionHeader("精剪", icon: "wand.and.stars")
            controls
            scanSection
            if let message = model.smartCutMessage {
                messageBlock(message)
            }
            if
                model.smartCutScanPhase == .ready,
                let analysis = model.smartCutAnalysis
            {
                summaryBlock(analysis)
                candidateList(analysis)
                applySection(analysis)
            }
            if project.supportsVoiceCamera {
                disclosureSection(
                    .smartCutVoice,
                    title: "语音驱动摄像头",
                    icon: "person.and.background.dotted",
                    summary: model.smartCutScanPhase == .ready
                        ? "可生成"
                        : "需先扫描"
                ) {
                    voiceCameraSection
                }
            }
            disclosureSection(
                .smartCutFiller,
                title: "口头禅与重说",
                icon: "text.badge.plus",
                summary: model.fillerSuggestions.isEmpty
                    ? "未分析"
                    : "\(model.fillerSuggestions.count) 条建议"
            ) {
                fillerSection
            }
        }
    }

    // MARK: 口头禅与重说建议

    private var fillerSection: some View {
        VStack(alignment: .leading, spacing: StudioTheme.space3) {
            HStack(spacing: StudioTheme.space3) {
                Button {
                    model.analyzeFillerSuggestions()
                } label: {
                    Label("分析字幕", systemImage: "text.magnifyingglass")
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, StudioTheme.space4)
                        .frame(height: 28)
                }
                .buttonStyle(SecondaryActionButtonStyle())
                .disabled(project.captionCues.isEmpty)

                if !model.fillerSuggestions.isEmpty {
                    Button("全不选") {
                        model.deselectAllFillerSuggestions()
                    }
                    .buttonStyle(GhostActionButtonStyle())
                    .font(.callout)
                    .foregroundStyle(StudioTheme.textSecondary)
                    Button("选择安全建议") {
                        model.selectAllSafeFillerSuggestions()
                    }
                    .buttonStyle(GhostActionButtonStyle())
                    .font(.callout)
                    .foregroundStyle(StudioTheme.textSecondary)
                }
                Spacer()
            }

            if !model.fillerSuggestions.isEmpty {
                // 按置信度分两档显示——高置信可批量勾，低置信
                // 逐条确认（下标仍指向 model.fillerSuggestions 原数组）。
                VStack(spacing: StudioTheme.space2) {
                    fillerGroup(
                        title: "高置信（默认勾选）",
                        entries: model.fillerSuggestions.enumerated()
                            .filter { $0.element.isRecommended }
                    )
                    fillerGroup(
                        title: "低置信（逐条确认）",
                        entries: model.fillerSuggestions.enumerated()
                            .filter { !$0.element.isRecommended }
                    )
                }


                    Text(
                        "将剪掉约 "
                            + String(
                                format: "%.1f",
                                model.selectedFillerEstimatedDuration
                            ) + " 秒"
                    )
                    .font(.callout)
                    .foregroundStyle(StudioTheme.textSecondary)

                // 应用会删除片段（可撤销），按映射表 §9.2 走 destructive 语义。
                Button {
                    model.applyFillerSuggestions()
                } label: {
                    Label(
                        "应用所选（\(model.fillerSelectedIndices.count)）",
                        systemImage: "checkmark.circle"
                    )
                    .font(.callout.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                }
                .buttonStyle(
                    SecondaryActionButtonStyle(destructive: true)
                )
                .disabled(model.fillerSelectedIndices.isEmpty)
                .help(
                    model.fillerSelectedIndices.isEmpty
                        ? "先勾选要剪掉的口头禅建议，再应用"
                        : ""
                )
            }
        }
    }

    /// 一档建议列表；空档不渲染标题。
    @ViewBuilder
    private func fillerGroup(
        title: String,
        entries: [(offset: Int, element: SmartCutFillerSuggestion)]
    ) -> some View {
        if !entries.isEmpty {
            Text(title)
                .font(.callout.weight(.medium))
                .foregroundStyle(StudioTheme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, StudioTheme.space1)
            ForEach(entries, id: \.offset) { entry in
                fillerRow(index: entry.offset, suggestion: entry.element)
            }
        }
    }

    private func fillerRow(
        index: Int,
        suggestion: SmartCutFillerSuggestion
    ) -> some View {
        let isSelected = model.fillerSelectedIndices.contains(index)
        return HStack(spacing: StudioTheme.space3) {
            Toggle("", isOn: Binding(
                get: { isSelected },
                set: { _ in model.toggleFillerSuggestion(index) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()

            VStack(alignment: .leading, spacing: StudioTheme.space1) {
                HStack(spacing: StudioTheme.space2) {
                    Text(fillerTitle(suggestion))
                        .font(.callout.weight(.medium))
                        .foregroundStyle(
                            suggestion.isRecommended
                                ? StudioTheme.textPrimary
                                : StudioTheme.textTertiary
                        )
                    if !suggestion.isRecommended {
                        Text("低置信度")
                            .font(.callout)
                            .padding(.horizontal, StudioTheme.space2)
                            .padding(.vertical, StudioTheme.space1)
                            .background(StudioTheme.surfaceRaised)
                            .clipShape(Capsule())
                            .foregroundStyle(StudioTheme.textSecondary)
                    }
                }
                Text(fillerDetail(suggestion))
                    .font(.callout)
                    .foregroundStyle(StudioTheme.textSecondary)
                    .lineLimit(2)
            }
            Spacer()

            if suggestion.kind == .repeatedPhrase || suggestion.kind == .restart {
                Toggle("保留最后一遍", isOn: Binding(
                    get: { suggestion.keepLastInstance },
                    set: { _ in model.toggleKeepLastFillerInstance(index) }
                ))
                .toggleStyle(.checkbox)
                .font(.callout)
                .foregroundStyle(StudioTheme.textSecondary)
            }

            Button {
                model.selectFillerSuggestion(index)
            } label: {
                Image(systemName: "waveform")
                    .font(.callout)
                    .foregroundStyle(StudioTheme.textSecondary)
            }
            .buttonStyle(IconButtonStyle())
            .help("跳到该建议前 1 秒")

            Button {
                model.auditionFillerSuggestion(index)
            } label: {
                Image(systemName: "play.circle")
                    .font(.callout)
                    .foregroundStyle(StudioTheme.textSecondary)
            }
            .buttonStyle(IconButtonStyle())
            .help("试听剪切后的效果")
        }
        .padding(.horizontal, StudioTheme.space3)
        .padding(.vertical, StudioTheme.space2)
        .background(
            RoundedRectangle(cornerRadius: StudioTheme.radiusM)
                .fill(StudioTheme.surfaceCanvas)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            model.selectFillerSuggestion(index)
        }
    }

    private func fillerTitle(_ suggestion: SmartCutFillerSuggestion) -> String {
        switch suggestion.kind {
        case .fillerWord:
            return "填充词「\(suggestion.context)」"
        case .repeatedPhrase:
            return "重复句 ×\(suggestion.repeatCount)"
        case .restart:
            return "疑似重说"
        case .inSentenceFiller:
            return "句内填充词「\(suggestion.context)」"
        }
    }

    private func fillerDetail(_ suggestion: SmartCutFillerSuggestion) -> String {
        let range = suggestion.activeRange()
        let confidence = Int((suggestion.confidence * 100).rounded())
        return "删 "
            + "\(formatDuration(range.lowerBound, precise: true)) – "
            + "\(formatDuration(range.upperBound, precise: true)) · 置信度 "
            + "\(confidence)% · \(suggestion.context)"
    }

    // MARK: 语音驱动摄像头

    private var voiceCameraSection: some View {
        VStack(alignment: .leading, spacing: StudioTheme.space3) {
            Text(
                "根据最近一次扫描的语音活动，在 1.5 秒以上的长静默期间让摄像头"
                    + "平滑让出画面，下一段说话前自动恢复；恢复点提前 0.2 秒，"
                    + "避免声音先于人出现。"
            )
            .font(.callout)
            .foregroundStyle(StudioTheme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

            let hasManualSegments = project.cameraSegments.contains {
                !project.smartCutAutoCameraSegmentIDs.contains($0.id)
            }
            Button {
                model.applyVoiceCameraSegments()
            } label: {
                Label(
                    "生成语音显隐段",
                    systemImage: "sparkles.rectangle.stack"
                )
                .font(.callout.weight(.medium))
                .frame(maxWidth: .infinity)
                .frame(height: 28)
            }
            .buttonStyle(SecondaryActionButtonStyle())
            .disabled(model.smartCutScanPhase != .ready)

            if hasManualSegments {
                Text("已有手动摄像头布局段：不会生成自动显隐段；如需使用请先删除手动布局段。")
                    .font(.callout)
                    .foregroundStyle(StudioTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("重复生成会替换上一次的自动段，不会叠加。")
                    .font(.callout)
                    .foregroundStyle(StudioTheme.textSecondary)
            }
        }
    }

    private func disclosureSection<Content: View>(
        _ section: InspectorSection,
        title: String,
        icon: String,
        summary: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        InspectorDisclosureSection(
            title: title,
            icon: icon,
            summary: summary,
            isExpanded: Binding(
                get: { expandedSections.contains(section) },
                set: { isExpanded in
                    if isExpanded {
                        expandedSections.insert(section)
                    } else {
                        expandedSections.remove(section)
                    }
                }
            ),
            content: content
        )
        .id(section.rawValue)
    }

    // MARK: 控件

    private var controls: some View {
        VStack(alignment: .leading, spacing: StudioTheme.space3) {
            // 「精剪」是自造词，迁移动户和长辈都猜不到——
            // 一句话说清这个页签做什么。
            Text("扫描口播停顿与气口，生成可逐条勾选的候选，一次应用剪掉。")
                .font(.callout)
                .foregroundStyle(StudioTheme.textSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            fieldBlock("节奏") {
                StudioSegmented(
                    selection: Binding(
                        get: { model.smartCutMode },
                        set: { model.setSmartCutMode($0) }
                    ),
                    options: Array(SmartCutMode.allCases),
                    title: { $0 == .natural ? "自然" : "紧凑" }
                )
            }
            Toggle(isOn: Binding(
                get: { model.smartCutProtectScreenActivity },
                set: { model.setSmartCutProtectScreenActivity($0) }
            )) {
                Text("保护画面操作")
                    .font(.subheadline)
                    .foregroundStyle(StudioTheme.textSecondary)
            }
            .toggleStyle(.checkbox)
            .help("停顿期间有点击或明显画面操作时，不推荐删除该段")

            Toggle(isOn: Binding(
                get: { model.smartCutProtectSystemSound },
                set: { model.setSmartCutProtectSystemSound($0) }
            )) {
                Text("保护系统声音")
                    .font(.subheadline)
                    .foregroundStyle(StudioTheme.textSecondary)
            }
            .toggleStyle(.checkbox)
            .help("停顿期间系统声音仍在播放时，不推荐删除该段")
        }
    }

    private var scanSection: some View {
        VStack(alignment: .leading, spacing: StudioTheme.space3) {
            HStack(spacing: StudioTheme.space3) {
                Button {
                    model.startSmartCutScan()
                } label: {
                    Label("扫描", systemImage: "wand.and.stars")
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, StudioTheme.space4)
                        .frame(height: 28)
                }
                .buttonStyle(PrimaryActionButtonStyle())
                .disabled(
                    model.smartCutScanPhase == .scanning
                        || project.trimDuration <= 0
                )

                if model.smartCutScanPhase == .scanning {
                    Button {
                        model.cancelSmartCutScan()
                    } label: {
                        Label("取消", systemImage: "xmark")
                            .font(.callout.weight(.medium))
                            .padding(.horizontal, StudioTheme.space4)
                            .frame(height: 28)
                    }
                    .buttonStyle(SecondaryActionButtonStyle())
                }
                Spacer()
                if
                    model.smartCutScanPhase != .idle,
                    model.smartCutScanPhase != .scanning
                {
                    Button {
                        model.clearSmartCutResults()
                    } label: {
                        Text("重置")
                            .font(.callout)
                            .foregroundStyle(StudioTheme.textSecondary)
                    }
                    .buttonStyle(GhostActionButtonStyle())
                    .help("清除当前候选，回到未扫描状态")
                }
            }
            if model.smartCutScanPhase == .scanning {
                ProgressView(value: max(0.02, model.smartCutScanProgress))
                    .progressViewStyle(.linear)
                    .tint(StudioTheme.playbackGold)
                Text("正在后台分析成片音频，可以继续使用编辑器…")
                    .font(.callout)
                    .foregroundStyle(StudioTheme.textSecondary)
            }
        }
    }

    // MARK: 结果

    private func summaryBlock(_ analysis: SmartCutAnalysis) -> some View {
        HStack(spacing: StudioTheme.space4) {
            summaryItem(
                "\(analysis.candidates.count)",
                label: "候选"
            )
            summaryItem(
                "\(model.smartCutSelectedIndices.count)",
                label: "已选"
            )
            summaryItem(
                formatDuration(estimatedSaved(analysis)),
                label: "预计节省"
            )
            Spacer()
        }
        .padding(StudioTheme.space3)
        .background(StudioTheme.surfaceCanvas)
        .clipShape(RoundedRectangle(cornerRadius: StudioTheme.radiusM))
    }

    private func summaryItem(_ value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: StudioTheme.space1) {
            Text(value)
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(StudioTheme.textPrimary)
            Text(label)
                .font(.callout)
                .foregroundStyle(StudioTheme.textSecondary)
        }
    }

    private func estimatedSaved(_ analysis: SmartCutAnalysis) -> Double {
        analysis.candidates.enumerated()
            .filter { model.smartCutSelectedIndices.contains($0.offset) }
            .reduce(0) { $0 + $1.element.savedDuration }
    }

    private func candidateList(_ analysis: SmartCutAnalysis) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: StudioTheme.space3) {
                Button("全不选") {
                    model.deselectAllSmartCutCandidates()
                }
                .buttonStyle(GhostActionButtonStyle())
                .font(.callout)
                .foregroundStyle(StudioTheme.textSecondary)
                Button("选择安全建议") {
                    model.selectAllSafeSmartCutCandidates()
                }
                .buttonStyle(GhostActionButtonStyle())
                .font(.callout)
                .foregroundStyle(StudioTheme.textSecondary)
                Spacer()
            }
            .padding(.bottom, StudioTheme.space2)

            ScrollView {
                VStack(spacing: StudioTheme.space2) {
                    ForEach(
                        Array(analysis.candidates.enumerated()),
                        id: \.offset
                    ) { index, candidate in
                        candidateRow(index: index, candidate: candidate)
                    }
                }
            }
            .frame(maxHeight: 240)
        }
    }

    private func candidateRow(
        index: Int,
        candidate: SmartCutCandidate
    ) -> some View {
        let isSelected = model.smartCutSelectedIndices.contains(index)
        let isHighlighted = highlightedCandidateIndex == index
        return HStack(spacing: StudioTheme.space3) {
            Toggle("", isOn: Binding(
                get: { isSelected },
                set: { _ in model.toggleSmartCutCandidate(index) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()

            HStack(spacing: StudioTheme.space2) {
                // 双通道：可删除建议加图谱蓝剪刀图标，不只靠文字区分。
                if !candidate.kind.isProtected {
                    Image(systemName: "scissors")
                        .font(.callout)
                        .foregroundStyle(StudioTheme.accent)
                }
                VStack(alignment: .leading, spacing: StudioTheme.space1) {
                    Text(rowTitle(candidate))
                        .font(.callout.weight(.medium))
                        .foregroundStyle(
                            candidate.kind.isProtected
                                ? StudioTheme.textTertiary
                                : StudioTheme.textPrimary
                        )
                    Text(rowDetail(candidate))
                        .font(.callout)
                        .foregroundStyle(StudioTheme.textSecondary)
                }
            }
            Spacer()
            Button {
                model.selectSmartCutCandidate(index)
            } label: {
                Image(systemName: "waveform")
                    .font(.callout)
                    .foregroundStyle(StudioTheme.textSecondary)
            }
            .buttonStyle(IconButtonStyle())
            .help("跳到该停顿前 1 秒")

            Button {
                model.auditionSmartCutCandidate(index)
            } label: {
                Image(systemName: "play.circle")
                    .font(.callout)
                    .foregroundStyle(StudioTheme.textSecondary)
            }
            .buttonStyle(IconButtonStyle())
            .help("试听剪切后的效果")
        }
        .padding(.horizontal, StudioTheme.space3)
        .padding(.vertical, StudioTheme.space2)
        .background(
            RoundedRectangle(cornerRadius: StudioTheme.radiusM)
                .fill(
                    isHighlighted
                        ? StudioTheme.selectionTint
                        : StudioTheme.surfaceCanvas
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            model.selectSmartCutCandidate(index)
        }
    }

    private var highlightedCandidateIndex: Int? {
        analysisCandidates.firstIndex { candidate in
            model.currentTime >= candidate.start - 0.001
                && model.currentTime <= candidate.end + 0.001
        }
    }

    private var analysisCandidates: [SmartCutCandidate] {
        model.smartCutAnalysis?.candidates ?? []
    }

    private func rowTitle(_ candidate: SmartCutCandidate) -> String {
        switch candidate.kind {
        case .pureSpeechPause:
            return "纯说话停顿"
        case .shortBreath:
            return "短气口"
        case .hasScreenActivity:
            return "有屏幕操作（默认不删）"
        case .hasSystemSound:
            return "有系统声音（默认不删）"
        case .fillerWord:
            return "口头禅 / 填充词"
        case .repeatedTake:
            return "重复句 / 重说"
        }
    }

    private func rowDetail(_ candidate: SmartCutCandidate) -> String {
        "\(formatDuration(candidate.start, precise: true)) – "
            + "\(formatDuration(candidate.end, precise: true)) · 停顿 "
            + String(format: "%.1f", candidate.pauseDuration) + " 秒 · 可省 "
            + String(format: "%.1f", candidate.savedDuration) + " 秒"
    }

    private func applySection(_ analysis: SmartCutAnalysis) -> some View {
        VStack(alignment: .leading, spacing: StudioTheme.space2) {
            // 应用会删除片段（可撤销），按映射表 §9.2 走 destructive 语义。
            Button {
                model.applySmartCutSelection()
            } label: {
                Label(
                    "应用所选（\(model.smartCutSelectedIndices.count)）",
                    systemImage: "checkmark.circle"
                )
                .font(.callout.weight(.medium))
                .frame(maxWidth: .infinity)
                .frame(height: 30)
            }
            .buttonStyle(
                SecondaryActionButtonStyle(destructive: true)
            )
            .disabled(model.smartCutSelectedIndices.isEmpty)
            .help(
                model.smartCutSelectedIndices.isEmpty
                    ? "先勾选要剪掉的停顿候选，再应用"
                    : ""
            )
        }
    }

    private func messageBlock(_ message: String) -> some View {
        Text(message)
            .font(.callout)
            .foregroundStyle(
                model.smartCutScanPhase == .failed
                    ? StudioTheme.errorText
                    : StudioTheme.textSecondary
            )
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: 样式辅助（本面板独立于 EditorView 的私有 helper）

    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: StudioTheme.space2) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(StudioTheme.accent)
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(StudioTheme.textPrimary)
            Spacer()
        }
    }

    private func fieldBlock<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: StudioTheme.space2) {
            Text(title)
                .font(.callout)
                .foregroundStyle(StudioTheme.textSecondary)
            content()
        }
    }
}
