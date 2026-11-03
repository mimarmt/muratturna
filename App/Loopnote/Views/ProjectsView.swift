import SwiftData
import SwiftUI

struct ProjectsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Project.createdAt) private var projects: [Project]

    @State private var newName = ""
    @State private var showingNew = false

    var body: some View {
        List {
            ForEach(projects) { project in
                ProjectRow(project: project) { commit() }
            }
            .onDelete { offsets in
                for i in offsets { context.delete(projects[i]) }
                commit()
            }
        }
        .overlay {
            if projects.isEmpty {
                ContentUnavailableView("No projects", systemImage: "square.stack",
                                       description: Text("Group notes by project and silence a whole project with one tap."))
            }
        }
        .navigationTitle("Projects")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            ToolbarItem(placement: .primaryAction) {
                Button { showingNew = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("New project")
            }
        }
        .alert("New project", isPresented: $showingNew) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) { newName = "" }
            Button("Add") {
                let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                let color = Theme.projectPalette[projects.count % Theme.projectPalette.count]
                context.insert(Project(name: name, colorHex: color))
                newName = ""
                commit()
            }
        }
    }

    private func commit() {
        try? context.save()
        Task { await AlertScheduler.shared.reschedule() }
    }
}

private struct ProjectRow: View {
    @Bindable var project: Project
    var onChange: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Menu {
                ForEach(Theme.projectPalette, id: \.self) { hex in
                    Button {
                        project.colorHex = hex
                        onChange()
                    } label: {
                        Label(hex, systemImage: project.colorHex == hex ? "checkmark.circle.fill" : "circle.fill")
                    }
                    .tint(Color(hex: hex))
                }
            } label: {
                Circle().fill(Color(hex: project.colorHex)).frame(width: 14, height: 14)
            }
            .accessibilityLabel("Color")

            VStack(alignment: .leading, spacing: 2) {
                Text(project.name).font(Theme.title(.body))
                let active = (project.notes ?? []).filter { !$0.isCompleted }.count
                Text("\(active) active notes").font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(isOn: Binding(get: { !project.isMuted }, set: { project.isMuted = !$0; onChange() })) {
                Image(systemName: project.isMuted ? "speaker.slash" : "speaker.wave.2")
            }
            .labelsHidden()
            .accessibilityLabel("Speaks")
        }
        .padding(.vertical, 4)
    }
}
