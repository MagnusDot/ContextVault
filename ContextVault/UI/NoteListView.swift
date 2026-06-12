import SwiftUI

struct NoteListView: View {
    @Environment(VaultManager.self) private var vault
    let project: Project
    @Binding var selectedNote: Note?
    let searchText: String

    private var notes: [Note] {
        searchText.isEmpty
            ? vault.notes(for: project)
            : vault.searchNotes(query: searchText, in: project)
    }

    var body: some View {
        List {
            ForEach(notes) { note in
                Button {
                    selectedNote = note
                } label: {
                    NoteRowView(note: note)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(
                    selectedNote?.id == note.id ? Color.accentColor.opacity(0.1) : Color.clear
                )
                .contextMenu {
                    Button(role: .destructive) { delete(note) } label: {
                        Label("Delete Note", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.inset)
        .navigationTitle(project.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: newNote) {
                    Label("New Note", systemImage: "square.and.pencil")
                }
            }
        }
        .overlay {
            if notes.isEmpty {
                if searchText.isEmpty {
                    ContentUnavailableView {
                        Label("No Notes", systemImage: "doc.text")
                    } description: {
                        Text("Create your first note for \(project.name).")
                    } actions: {
                        Button("New Note", action: newNote)
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    ContentUnavailableView.search(text: searchText)
                }
            }
        }
    }

    private func newNote() {
        let note = Note(title: "Untitled", body: "", projectSlug: project.slug)
        try? vault.writeNote(note, to: project)
        selectedNote = vault.notes(for: project).first { $0.id == note.id }
    }

    private func delete(_ note: Note) {
        if selectedNote?.id == note.id { selectedNote = nil }
        try? vault.deleteNote(note, from: project)
    }
}

private struct NoteRowView: View {
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(note.title)
                .font(.body)
                .foregroundStyle(.primary)
                .lineLimit(1)

            HStack(spacing: 6) {
                if let claudeDate = note.lastClaudeModifiedAt {
                    Image(systemName: "brain")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                    Text(claudeDate, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(note.updatedAt, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !note.tags.isEmpty {
                    ForEach(note.tags.prefix(3), id: \.self) { tag in
                        Text(tag)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 3)
    }
}
