import SwiftUI

struct NoteEditorView: View {
    @Environment(VaultManager.self) private var vault
    let project: Project
    @State private var note: Note
    @AppStorage("contextvault.showPreview") private var showPreview = false
    @State private var saveTask: Task<Void, Never>?
    @State private var isDirty = false

    init(note: Note, project: Project) {
        self.project = project
        self._note = State(initialValue: note)
    }

    var body: some View {
        Group {
            if showPreview {
                previewView
            } else {
                editorView
            }
        }
        .navigationTitle($note.title)
        .navigationSubtitle(note.updatedAt.formatted(.relative(presentation: .named)))
        .toolbar { toolbar }
        .onDisappear {
            saveTask?.cancel()
            if isDirty { try? vault.writeNote(note, to: project) }
        }
    }

    // MARK: - Editor

    private var editorView: some View {
        TextEditor(text: $note.body)
            .font(.system(.body, design: .monospaced))
            .scrollContentBackground(.hidden)
            .background(Color(.textBackgroundColor))
            .contentMargins(.all, 24, for: .scrollContent)
            .onChange(of: note.body) { _, _ in isDirty = true; scheduleSave() }
            .onChange(of: note.title) { _, _ in isDirty = true; scheduleSave() }
    }

    // MARK: - Preview

    private var previewView: some View {
        MarkdownPreviewView(markdown: note.body)
            .background(Color(.textBackgroundColor))
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(isOn: $showPreview) {
                Label(
                    showPreview ? "Edit" : "Preview",
                    systemImage: showPreview ? "pencil" : "eye"
                )
            }
            .toggleStyle(.button)
            .help(showPreview ? "Switch to editor" : "Preview rendered Markdown")
        }

        ToolbarItem(placement: .secondaryAction) {
            TagPickerButton(tags: $note.tags, onChange: { isDirty = true; scheduleSave() })
        }

        ToolbarItem(placement: .secondaryAction) {
            Button(action: { try? vault.writeNote(note, to: project) }) {
                Label("Save", systemImage: "checkmark")
            }
            .help("Save now (auto-saved on change)")
        }
    }

    // MARK: - Helpers

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            try? vault.writeNote(note, to: project)
        }
    }
}

// MARK: - Tag picker

private struct TagPickerButton: View {
    @Binding var tags: [String]
    var onChange: () -> Void
    @State private var isPresented = false
    @State private var input = ""

    var body: some View {
        Button { isPresented = true } label: {
            Label(tags.isEmpty ? "Tags" : tags.prefix(2).joined(separator: ", "), systemImage: "tag")
        }
        .help("Edit tags")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            tagPopover
        }
    }

    private var tagPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Tags")
                .font(.headline)

            if tags.isEmpty {
                Text("No tags yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(tags, id: \.self) { tag in
                        HStack(spacing: 4) {
                            Text(tag).font(.caption)
                            Button {
                                tags.removeAll { $0 == tag }
                                onChange()
                            } label: {
                                Image(systemName: "xmark").imageScale(.small)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: Capsule())
                    }
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(.tint)
                    .imageScale(.small)
                TextField("Add tag…", text: $input)
                    .textFieldStyle(.plain)
                    .onSubmit { addTag() }
            }
            .padding(8)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(16)
        .frame(width: 220)
    }

    private func addTag() {
        let t = input.trimmingCharacters(in: .whitespaces).lowercased()
        guard !t.isEmpty, !tags.contains(t) else { input = ""; return }
        tags.append(t)
        input = ""
        onChange()
    }
}
