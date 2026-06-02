import SwiftUI

public struct WorkoutDetailSheet: View {
    @ObservedObject var vm: WorkoutDetailViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showingNoteEditor: Bool = false
    @State private var pendingStatus: WorkoutStatus?
    @State private var saveError: String?

    public init(vm: WorkoutDetailViewModel) {
        self.vm = vm
    }

    private var sortedBlocks: [WorkoutBlock] {
        vm.workout.blocks.sorted { $0.order < $1.order }
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    hero
                    if !vm.workout.summary.isEmpty {
                        summary
                    }
                    ForEach(sortedBlocks) { block in
                        blockSection(block)
                    }
                    if showingNoteEditor {
                        noteEditor
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                    Color.clear.frame(height: 8)
                }
                .padding(.horizontal, 24)
                .padding(.top, 4)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .background(Color(.systemBackground))
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.primary)
                            .frame(width: 30, height: 30)
                            .background(.gray.opacity(0.12), in: Circle())
                    }
                    .accessibilityLabel("Close")
                }
            }
            .safeAreaInset(edge: .bottom) {
                actionBar
            }
            .animation(.easeInOut(duration: 0.22), value: showingNoteEditor)
            .animation(.easeInOut(duration: 0.22), value: vm.workout.statusRaw)
            .alert("Couldn’t save",
                   isPresented: Binding(get: { saveError != nil },
                                        set: { if !$0 { saveError = nil } })) {
                Button("OK") { saveError = nil }
            } message: {
                Text(saveError ?? "")
            }
        }
    }

    // MARK: – Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(dateLine)
                .font(.system(.caption, design: .monospaced).weight(.bold))
                .tracking(2)
                .foregroundStyle(.secondary)
            Text(vm.workout.title)
                .font(.system(.largeTitle, design: .serif).weight(.bold))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Rectangle()
                .fill(.primary.opacity(0.15))
                .frame(height: 1)
                .padding(.top, 4)
            HStack(spacing: 8) {
                statusPill
                ForEach(kindChips, id: \.self) { kind in
                    kindChip(kind)
                }
                Spacer()
            }
        }
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            Image(systemName: statusIcon).font(.caption2.weight(.bold))
            Text(statusLabel.uppercased())
                .font(.system(.caption2, design: .monospaced).weight(.bold))
                .tracking(1.4)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .foregroundStyle(statusColor)
        .background(statusColor.opacity(0.12), in: Capsule())
        .overlay(Capsule().stroke(statusColor.opacity(0.3), lineWidth: 1))
    }

    private func kindChip(_ kind: BlockKind) -> some View {
        HStack(spacing: 5) {
            Text(symbol(for: kind)).font(.caption)
            Text(defaultTitle(for: kind).uppercased())
                .font(.system(.caption2, design: .monospaced).weight(.bold))
                .tracking(1.2)
                .foregroundStyle(.primary.opacity(0.65))
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.primary.opacity(0.05), in: Capsule())
    }

    // MARK: – Summary

    private var summary: some View {
        Text(vm.workout.summary)
            .font(.system(.body, design: .serif))
            .lineSpacing(5)
            .foregroundStyle(.primary.opacity(0.82))
    }

    // MARK: – Block section

    private func blockSection(_ b: WorkoutBlock) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            blockHeader(b)
            blockContent(b)
        }
    }

    private func blockHeader(_ b: WorkoutBlock) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Rectangle()
                .fill(.primary.opacity(0.12))
                .frame(height: 1)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(symbol(for: b.kind)).font(.title3)
                Text((b.title.isEmpty ? defaultTitle(for: b.kind) : b.title).uppercased())
                    .font(.system(.subheadline, design: .default).weight(.heavy))
                    .tracking(1.2)
                Spacer()
            }
        }
    }

    @ViewBuilder
    private func blockContent(_ b: WorkoutBlock) -> some View {
        switch b.kind {
        case .strength: strengthDetail(b)
        case .cardio:   cardioDetail(b)
        case .mobility: mobilityDetail(b)
        }
    }

    private func strengthDetail(_ b: WorkoutBlock) -> some View {
        let exercises: [Exercise] = b.exercises.sorted { $0.order < $1.order }
        return VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(exercises.enumerated()), id: \.element.id) { idx, e in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(String(format: "%02d", idx + 1))
                        .font(.system(.caption, design: .monospaced).weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, alignment: .leading)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(e.name).font(.body.weight(.semibold))
                        Text(setRepLine(e))
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Spacer()
                }
            }
            if !b.notes.isEmpty {
                blockNote(b.notes)
            }
        }
    }

    @ViewBuilder
    private func cardioDetail(_ b: WorkoutBlock) -> some View {
        if let c = b.cardio {
            VStack(alignment: .leading, spacing: 14) {
                metricRow("Modality", c.modality)
                if let m = c.durationMinutes {
                    metricRow("Duration", "\(m) min")
                }
                if let d = c.distanceMeters {
                    metricRow("Distance", "\(Int(d.rounded())) m")
                }
                if let t = c.targetDescription, !t.isEmpty {
                    metricRow("Target", t)
                }
                if !b.notes.isEmpty {
                    blockNote(b.notes)
                }
            }
        } else if !b.notes.isEmpty {
            blockNote(b.notes)
        }
    }

    private func mobilityDetail(_ b: WorkoutBlock) -> some View {
        Text(b.notes.isEmpty ? "Flow at your own pace." : b.notes)
            .font(.system(.body, design: .serif))
            .foregroundStyle(.primary.opacity(0.8))
            .lineSpacing(4)
    }

    private func metricRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(label.uppercased())
                .font(.system(.caption2, design: .monospaced).weight(.bold))
                .tracking(1.4)
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .leading)
            Text(value)
                .font(.system(.body, design: .default))
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func blockNote(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Rectangle()
                .fill(.primary.opacity(0.25))
                .frame(width: 2)
            Text(text)
                .font(.system(.footnote, design: .serif).italic())
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }

    // MARK: – Note editor

    private var noteEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Note · Optional")
                .font(.system(.caption2, design: .monospaced).weight(.bold))
                .tracking(1.5)
                .foregroundStyle(.secondary)
            TextField("How did it go?", text: $vm.draftNote, axis: .vertical)
                .font(.system(.body, design: .serif))
                .lineLimit(2...6)
                .padding(14)
                .background(.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            HStack(spacing: 10) {
                Button {
                    vm.draftNote = ""
                    save()
                } label: {
                    Text("SKIP")
                        .font(.system(.caption, design: .monospaced).weight(.bold))
                        .tracking(1.3)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button { save() } label: {
                    Text("SAVE")
                        .font(.system(.caption, design: .monospaced).weight(.bold))
                        .tracking(1.3)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.primary)
                .controlSize(.large)
            }
        }
        .padding(18)
        .background(.gray.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.primary.opacity(0.08), lineWidth: 1))
    }

    // MARK: – Action bar

    @ViewBuilder
    private var actionBar: some View {
        if showingNoteEditor {
            EmptyView()
        } else {
            HStack(spacing: 12) {
                switch vm.workout.status {
                case .pending:
                    Button {
                        pendingStatus = .failed
                        showingNoteEditor = true
                    } label: {
                        actionLabel("Failed", systemImage: "xmark")
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .controlSize(.large)

                    Button {
                        pendingStatus = .completed
                        showingNoteEditor = true
                    } label: {
                        actionLabel("Complete", systemImage: "checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.primary)
                    .controlSize(.large)

                case .completed, .failed:
                    Button {
                        pendingStatus = .pending
                        resetStatus()
                    } label: {
                        actionLabel("Reset to pending", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .background(.bar)
        }
    }

    private func actionLabel(_ text: String, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage).font(.caption.weight(.bold))
            Text(text.uppercased())
                .font(.system(.caption, design: .monospaced).weight(.bold))
                .tracking(1.4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
    }

    // MARK: – Helpers

    private static let dateLineFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE · MMM d · yyyy"
        return f
    }()

    private var dateLine: String {
        Self.dateLineFormatter.string(from: vm.workout.date).uppercased()
    }

    private var kindChips: [BlockKind] {
        var seen = Set<BlockKind>()
        var out: [BlockKind] = []
        for k in sortedBlocks.map(\.kind) where seen.insert(k).inserted {
            out.append(k)
        }
        return out
    }

    private func symbol(for kind: BlockKind) -> String {
        switch kind {
        case .strength: return "💪"
        case .cardio:   return "🏃"
        case .mobility: return "🧘"
        }
    }

    private func defaultTitle(for kind: BlockKind) -> String {
        switch kind {
        case .strength: return "Strength"
        case .cardio:   return "Cardio"
        case .mobility: return "Mobility"
        }
    }

    private func setRepLine(_ e: Exercise) -> String {
        var s = "\(e.sets) × \(e.reps)"
        if let load = e.load, !load.isEmpty { s += "  @  \(load)" }
        if let rest = e.restSeconds { s += "   ·   \(rest)s rest" }
        return s
    }

    private var statusLabel: String {
        switch vm.workout.status {
        case .pending:   return "Pending"
        case .completed: return "Completed"
        case .failed:    return "Failed"
        }
    }

    private var statusIcon: String {
        switch vm.workout.status {
        case .pending:   return "circle"
        case .completed: return "checkmark.circle.fill"
        case .failed:    return "xmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch vm.workout.status {
        case .pending:   return .secondary
        case .completed: return .green
        case .failed:    return .red
        }
    }

    private func save() {
        do {
            switch pendingStatus {
            case .completed: try vm.markCompleted()
            case .failed:    try vm.markFailed()
            case .pending, nil: break
            }
            showingNoteEditor = false
            pendingStatus = nil
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func resetStatus() {
        do {
            vm.draftNote = ""
            try vm.markPending()
        } catch {
            saveError = error.localizedDescription
        }
    }
}
