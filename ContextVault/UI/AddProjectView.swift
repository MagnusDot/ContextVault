import SwiftUI

struct AddProjectView: View {
    @Environment(VaultManager.self) private var vault
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var rootPath = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Name") {
                        TextField("My Project", text: $name)
                    }
                    LabeledContent("Root path") {
                        HStack {
                            TextField("/Users/me/projects/myapp", text: $rootPath)
                            Button("Browse…") { browse() }
                                .buttonStyle(.bordered)
                        }
                    }
                } header: {
                    Text("Project details")
                } footer: {
                    Text("The root directory of your code repository. Claude Code will auto-select this vault when working inside that folder.")
                        .foregroundStyle(.secondary)
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Add Project")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || rootPath.isEmpty)
                }
            }
        }
        .frame(width: 440, height: 260)
    }

    private func add() {
        let project = Project(name: name.trimmingCharacters(in: .whitespaces), rootPath: rootPath)
        do {
            try vault.addProject(project)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select your project's root directory"
        panel.prompt = "Select"
        if panel.runModal() == .OK {
            rootPath = panel.url?.path(percentEncoded: false) ?? ""
            if name.isEmpty, let last = panel.url?.lastPathComponent {
                name = last
            }
        }
    }
}
