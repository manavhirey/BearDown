import SwiftUI

public struct WorkoutDetailSheet: View {
    @ObservedObject var vm: WorkoutDetailViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showingNoteEditor: Bool = false
    @State private var pendingStatus: WorkoutStatus?

    public init(vm: WorkoutDetailViewModel) {
        self.vm = vm
    }

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(vm.workout.summary).foregroundStyle(.secondary)
                }
                ForEach(vm.workout.blocks.sorted(by: { $0.order < $1.order })) { b in
                    Section(header: Text(headerLabel(b))) {
                        if b.kind == .strength {
                            ForEach(b.exercises.sorted(by: { $0.order < $1.order })) { e in
                                VStack(alignment: .leading) {
                                    Text(e.name).bold()
                                    Text("\(e.sets) × \(e.reps)\(e.load.map { " @ \($0)" } ?? "")")
                                        .foregroundStyle(.secondary).font(.footnote)
                                }
                            }
                            if !b.notes.isEmpty { Text(b.notes).font(.footnote).foregroundStyle(.secondary) }
                        } else if b.kind == .cardio, let c = b.cardio {
                            Text(c.modality).bold()
                            if let mins = c.durationMinutes { Text("\(mins) min").foregroundStyle(.secondary) }
                            if let d = c.distanceMeters { Text(String(format: "%.0f m", d)).foregroundStyle(.secondary) }
                            if let t = c.targetDescription { Text(t).foregroundStyle(.secondary) }
                            if !b.notes.isEmpty { Text(b.notes).font(.footnote).foregroundStyle(.secondary) }
                        } else {
                            Text(b.notes.isEmpty ? "(mobility)" : b.notes).foregroundStyle(.secondary)
                        }
                    }
                }
                if showingNoteEditor {
                    Section("Note (optional)") {
                        TextField("How did it go?", text: $vm.draftNote, axis: .vertical)
                            .lineLimit(1...4)
                        HStack {
                            Button("Skip") {
                                vm.draftNote = ""
                                save()
                            }
                            Spacer()
                            Button("Save") { save() }.buttonStyle(.borderedProminent)
                        }
                    }
                }
            }
            .navigationTitle(vm.workout.title)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu(currentLabel()) {
                        Button("Mark Completed") { pendingStatus = .completed; showingNoteEditor = true }
                        Button("Mark Failed", role: .destructive) { pendingStatus = .failed; showingNoteEditor = true }
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func headerLabel(_ b: WorkoutBlock) -> String {
        switch b.kind {
        case .strength: return "💪 \(b.title.isEmpty ? "Strength" : b.title)"
        case .cardio:   return "🏃 \(b.title.isEmpty ? "Cardio" : b.title)"
        case .mobility: return "🧘 \(b.title.isEmpty ? "Mobility" : b.title)"
        }
    }

    private func currentLabel() -> String {
        switch vm.workout.status {
        case .pending:   return "Mark…"
        case .completed: return "✓ Completed"
        case .failed:    return "✗ Failed"
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
        } catch { /* surfaced by Workout query refreshing */ }
    }
}
