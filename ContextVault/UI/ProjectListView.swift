import SwiftUI

struct ProjectListView: View {
    @Environment(VaultManager.self) private var vault
    @Binding var selectedProject: Project?
    var onProjectTap: (Project) -> Void = { _ in }
    @State private var showingAdd = false
    @State private var projectToDelete: Project?

    var body: some View {
        List {
            Button {
                selectedProject = nil
            } label: {
                Label("Home", systemImage: "house.fill")
                    .foregroundStyle(selectedProject == nil ? Color.accentColor : Color.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowSeparator(.hidden)
            .listRowBackground(selectedProject == nil ? Color.accentColor.opacity(0.1) : Color.clear)
            .padding(.bottom, 4)

            ForEach(vault.projects) { project in
                Button {
                    selectedProject = project
                    onProjectTap(project)
                } label: {
                    ProjectRowView(project: project, noteCount: vault.noteCount(for: project))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(
                    selectedProject?.id == project.id ? Color.accentColor.opacity(0.1) : Color.clear
                )
                .contextMenu {
                    Button(role: .destructive) { projectToDelete = project } label: {
                        Label("Remove Project…", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Projects")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingAdd = true } label: {
                    Label("Add Project", systemImage: "plus")
                }
            }
        }
        .overlay {
            if vault.projects.isEmpty {
                ContentUnavailableView {
                    Label("No Projects", systemImage: "folder")
                } description: {
                    Text("Add a project to get started.")
                } actions: {
                    Button("Add Project") { showingAdd = true }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .sheet(isPresented: $showingAdd) {
            AddProjectView()
                .environment(vault)
        }
        .confirmationDialog(
            "Remove \"\(projectToDelete?.name ?? "")\"?",
            isPresented: Binding(get: { projectToDelete != nil }, set: { if !$0 { projectToDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let p = projectToDelete {
                    if selectedProject?.id == p.id { selectedProject = nil }
                    try? vault.removeProject(p)
                }
                projectToDelete = nil
            }
            Button("Cancel", role: .cancel) { projectToDelete = nil }
        } message: {
            Text("The vault notes will be deleted from disk.")
        }
    }
}

private struct ProjectRowView: View {
    let project: Project
    let noteCount: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.tint)
                .imageScale(.medium)
            VStack(alignment: .leading, spacing: 1) {
                Text(project.name)
                    .font(.body)
                Text(project.rootPath)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text("\(noteCount)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
        }
        .padding(.vertical, 2)
    }
}
