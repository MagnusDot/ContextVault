import SwiftUI
import AppKit

struct SetupGuideView: View {
    @Environment(MCPServer.self) private var mcp
    @State private var tab: Tab = .claudeCode

    enum Tab { case claudeCode, claudeDesktop }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "cable.connector")
                    .foregroundStyle(.secondary)
                Text("Connect to Claude")
                    .font(.headline)
                Spacer()
            }

            Picker("", selection: $tab) {
                Text("Claude Code").tag(Tab.claudeCode)
                Text("Claude Desktop").tag(Tab.claudeDesktop)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch tab {
            case .claudeCode:  ClaudeCodeSetup()
            case .claudeDesktop: ClaudeDesktopSetup()
            }
        }
        .padding(18)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.1), lineWidth: 1))
    }
}

// MARK: - Claude Code

private struct ClaudeCodeSetup: View {
    @Environment(MCPServer.self) private var mcp

    private let firstPrompt = """
    Commence par appeler get_project_context avec le chemin de ce projet \
    pour charger le contexte depuis ContextVault, puis résume ce que tu sais \
    du projet et demande-moi sur quoi on travaille aujourd'hui.
    """

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SetupStepRow(
                index: 1,
                done: mcp.isRunning,
                title: "Auto-configuré",
                detail: mcp.isRunning
                    ? "ContextVault est enregistré dans ~/.claude.json — aucune étape manuelle."
                    : "Démarrage du serveur MCP… ContextVault s'enregistrera dans ~/.claude.json."
            )

            SetupStepRow(
                index: 2,
                title: "Ouvre un terminal dans ton projet",
                detail: "Va dans le dossier du projet ajouté à ContextVault et lance Claude Code :",
                snippet: "claude"
            )

            SetupStepRow(
                index: 3,
                title: "Premier prompt",
                detail: "Colle ce prompt en début de session — Claude chargera son contexte et te demandera sur quoi travailler :",
                snippet: firstPrompt
            )
        }
    }
}

// MARK: - Claude Desktop

private struct ClaudeInstance: Identifiable {
    let id = UUID()
    let name: String
    let configURL: URL
    var isConfigured: Bool
    var errorMsg: String?

    nonisolated static func resolveBrewPath() -> String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    // Resolve npx path via a login shell so nvm/homebrew paths are found.
    // Validates the result is a real absolute path — on macOS `which` prints
    // "npx not found" to stdout (exit 1) when missing, which we must reject.
    nonisolated static func resolveNpxPath() -> String? {
        let proc = Process()
        let pipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-l", "-c", "which npx 2>/dev/null"]
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        guard (try? proc.run()) != nil else { return nil }
        proc.waitUntilExit()
        let raw = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let path = raw, path.hasPrefix("/"),
              FileManager.default.fileExists(atPath: path) else { return nil }
        return path
    }

    // Claude Desktop spawns processes without the user's PATH (no nvm, no homebrew).
    // Using the node binary directly + the resolved npx-cli.js script avoids both
    // the shebang (#!/usr/bin/env node) and the PATH lookup issues.
    static func desktopEntry(npxPath: String) -> [String: Any] {
        let binDir = URL(fileURLWithPath: npxPath).deletingLastPathComponent().path
        let nodePath = binDir + "/node"
        let npxScript = URL(fileURLWithPath: npxPath).resolvingSymlinksInPath().path

        if FileManager.default.isExecutableFile(atPath: nodePath),
           FileManager.default.fileExists(atPath: npxScript) {
            return [
                "command": nodePath,
                "args": [npxScript, "-y", "mcp-remote", "http://localhost:\(MCPHTTPServer.port)/sse"]
            ]
        }
        return [
            "command": npxPath,
            "args": ["-y", "mcp-remote", "http://localhost:\(MCPHTTPServer.port)/sse"]
        ]
    }

    static func discover() -> [ClaudeInstance] {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              let entries = try? FileManager.default.contentsOfDirectory(
                at: appSupport, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)
        else { return [] }

        let dirs = entries
            .filter {
                let name = $0.lastPathComponent
                return (name == "Claude" || name.hasPrefix("Claude-"))
                    && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
            .sorted { $0.lastPathComponent == "Claude" || $0.lastPathComponent < $1.lastPathComponent }

        return dirs.map { dir in
            let configURL = dir.appendingPathComponent("claude_desktop_config.json")
            return ClaudeInstance(name: dir.lastPathComponent, configURL: configURL,
                                  isConfigured: isAlreadyConfigured(at: configURL))
        }
    }

    static func isAlreadyConfigured(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = json["mcpServers"] as? [String: Any],
              let cv = servers["contextvault"] as? [String: Any],
              let command = cv["command"] as? String
        else { return false }
        // Treat configs with a non-existent command as not configured so the
        // user gets the "Configurer" button and overwrites the broken entry.
        return command.hasPrefix("/") && FileManager.default.fileExists(atPath: command)
    }

    mutating func configure(npxPath: String) {
        var config: [String: Any] = [:]
        if let data = try? Data(contentsOf: configURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            config = existing
        }
        var servers = config["mcpServers"] as? [String: Any] ?? [:]
        servers["contextvault"] = Self.desktopEntry(npxPath: npxPath)
        config["mcpServers"] = servers

        do {
            try FileManager.default.createDirectory(
                at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: configURL, options: .atomic)
            isConfigured = true
            errorMsg = nil
        } catch {
            errorMsg = error.localizedDescription
        }
    }
}

private struct ClaudeDesktopSetup: View {
    @State private var instances: [ClaudeInstance] = []
    @State private var npxPath: String? = nil
    @State private var brewPath: String? = nil
    @State private var npxDetected = false
    @State private var isInstallingNode = false
    @State private var showManual = false

    private var allConfigured: Bool { !instances.isEmpty && instances.allSatisfy(\.isConfigured) }
    private var unconfigured: [ClaudeInstance] { instances.filter { !$0.isConfigured } }
    private var canConfigure: Bool { npxPath != nil }

    private var manualSnippet: String {
        if let npx = npxPath {
            let entry = ClaudeInstance.desktopEntry(npxPath: npx)
            let cmd = entry["command"] as? String ?? npx
            let args = (entry["args"] as? [String] ?? []).map { "\"\($0)\"" }.joined(separator: ", ")
            return """
            {
              "mcpServers": {
                "contextvault": {
                  "command": "\(cmd)",
                  "args": [\(args)]
                }
              }
            }
            """
        }
        return """
        {
          "mcpServers": {
            "contextvault": {
              "command": "/path/to/node",
              "args": ["/path/to/npx-cli.js", "-y", "mcp-remote", "http://localhost:9877/sse"]
            }
          }
        }
        """
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SetupStepRow(
                index: 1,
                done: allConfigured,
                title: allConfigured ? "Toutes les instances configurées" : "Configurer Claude Desktop",
                detail: allConfigured
                    ? "ContextVault est enregistré dans toutes vos instances Claude Desktop."
                    : "Utilise mcp-remote comme bridge stdio→SSE (même approche qu'obsidian-mcp)."
            ) {
                npxStatus
                instanceList
                manualDisclosure
            }

            SetupStepRow(
                index: 2,
                title: "Redémarrer Claude Desktop",
                detail: "Les outils ContextVault apparaîtront dans le menu  de chaque instance configurée."
            )

            SetupStepRow(
                index: 3,
                title: "Premier prompt",
                detail: "Colle ce prompt en début de conversation pour que Claude charge son contexte :",
                snippet: """
                Commence par appeler get_project_context avec le chemin de ce projet \
                pour charger le contexte depuis ContextVault, puis résume ce que tu sais \
                du projet et demande-moi sur quoi on travaille aujourd'hui.
                """
            )
        }
        .onAppear {
            instances = ClaudeInstance.discover()
            Task.detached {
                let npx = ClaudeInstance.resolveNpxPath()
                let brew = ClaudeInstance.resolveBrewPath()
                await MainActor.run {
                    npxPath = npx
                    brewPath = brew
                    npxDetected = true
                }
            }
        }
    }

    // MARK: - npx status banner

    @ViewBuilder
    private var npxStatus: some View {
        if !npxDetected {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Recherche de Node.js…").font(.caption).foregroundStyle(.secondary)
            }
        } else if let path = npxPath {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(path)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
        } else if isInstallingNode {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Installation de Node.js via Homebrew…")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Node.js introuvable automatiquement").font(.caption.weight(.medium))
                }
                NpxManualField(npxPath: $npxPath)
                HStack(spacing: 8) {
                    if let brew = brewPath {
                        Button {
                            installNodeViaHomebrew(brewPath: brew)
                        } label: {
                            Label("Installer via Homebrew", systemImage: "arrow.down.circle")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    Button {
                        NSWorkspace.shared.open(URL(string: "https://nodejs.org")!)
                    } label: {
                        Label("Télécharger Node.js", systemImage: "safari")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    private func installNodeViaHomebrew(brewPath: String) {
        isInstallingNode = true
        Task.detached {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: brewPath)
            proc.arguments = ["install", "node"]
            proc.standardOutput = Pipe()
            proc.standardError = Pipe()
            try? proc.run()
            proc.waitUntilExit()

            let npx = ClaudeInstance.resolveNpxPath()
            await MainActor.run {
                isInstallingNode = false
                npxPath = npx
            }
        }
    }

    // MARK: - Instance list

    @ViewBuilder
    private var instanceList: some View {
        if instances.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
                Text("Aucune instance Claude Desktop trouvée dans Application Support.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach($instances) { $instance in
                    InstanceRow(instance: $instance, npxPath: npxPath)
                }
            }
            .padding(.vertical, 4)
        }

        HStack(spacing: 8) {
            if unconfigured.count > 1, let path = npxPath {
                Button {
                    for i in instances.indices where !instances[i].isConfigured {
                        instances[i].configure(npxPath: path)
                    }
                } label: {
                    Label("Tout configurer", systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            Button { addCustomInstance() } label: {
                Label("Ajouter un profil custom…", systemImage: "plus")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    // MARK: - Manual disclosure

    @ViewBuilder
    private var manualDisclosure: some View {
        DisclosureGroup("Faire manuellement", isExpanded: $showManual) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Ajoutez dans la section **mcpServers** du `claude_desktop_config.json` :")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                CodeSnippet(text: manualSnippet)
            }
            .padding(.top, 8)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: - Add custom path

    private func addCustomInstance() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Sélectionnez le dossier --user-data-dir de votre instance Claude"
        panel.prompt = "Choisir"
        panel.directoryURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first

        guard panel.runModal() == .OK, let dir = panel.url else { return }

        let configURL = dir.appendingPathComponent("claude_desktop_config.json")
        guard !instances.contains(where: { $0.configURL == configURL }) else { return }

        let instance = ClaudeInstance(
            name: dir.lastPathComponent,
            configURL: configURL,
            isConfigured: ClaudeInstance.isAlreadyConfigured(at: configURL)
        )
        instances.append(instance)
    }
}

// MARK: - Single instance row

private struct InstanceRow: View {
    @Binding var instance: ClaudeInstance
    let npxPath: String?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: instance.isConfigured ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(instance.isConfigured ? Color.green : Color.secondary)
                .imageScale(.small)

            VStack(alignment: .leading, spacing: 1) {
                Text(instance.name).font(.body)
                if let err = instance.errorMsg {
                    Text(err).font(.caption2).foregroundStyle(.red)
                }
            }

            Spacer()

            if instance.isConfigured {
                Text("Configuré").font(.caption2).foregroundStyle(.secondary)
            } else if let path = npxPath {
                Button("Configurer") { instance.configure(npxPath: path) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else {
                Text("Node.js requis").font(.caption2).foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 7))
    }
}

// MARK: - Manual npx path input

private struct NpxManualField: View {
    @Binding var npxPath: String?
    @State private var text = ""
    @State private var error: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                TextField("/usr/local/bin/npx", text: $text)
                    .font(.system(.caption, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { validate() }
                Button("OK") { validate() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let err = error {
                Text(err).font(.caption2).foregroundStyle(.red)
            } else {
                Text("Colle le chemin de npx ou node (ex: \(NSString("~/.nvm/versions/node/vX.Y.Z/bin/npx").expandingTildeInPath))")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private func validate() {
        var path = text.trimmingCharacters(in: .whitespaces)
        path = NSString(string: path).expandingTildeInPath
        guard !path.isEmpty else { return }
        guard path.hasPrefix("/") else {
            error = "Le chemin doit être absolu (commencer par /)."
            return
        }
        guard FileManager.default.isExecutableFile(atPath: path) else {
            error = "Fichier introuvable ou non exécutable : \(path)"
            return
        }
        // If user gave `node`, look for npx alongside it
        let url = URL(fileURLWithPath: path)
        if url.lastPathComponent == "node" {
            let sibling = url.deletingLastPathComponent().appendingPathComponent("npx").path
            path = FileManager.default.fileExists(atPath: sibling) ? sibling : path
        }
        error = nil
        npxPath = path
    }
}

// MARK: - Reusable step row

private struct SetupStepRow<Extra: View>: View {
    let index: Int
    var done: Bool = false
    let title: String
    let detail: String
    var snippet: String? = nil
    @ViewBuilder var extra: () -> Extra

    init(index: Int, done: Bool = false, title: String, detail: String, snippet: String? = nil,
         @ViewBuilder extra: @escaping () -> Extra = { EmptyView() }) {
        self.index = index
        self.done = done
        self.title = title
        self.detail = detail
        self.snippet = snippet
        self.extra = extra
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            stepBadge
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let snippet {
                    CodeSnippet(text: snippet)
                }
                extra()
            }
        }
    }

    private var stepBadge: some View {
        ZStack {
            Circle()
                .fill(done ? Color.green : Color.accentColor.opacity(0.12))
                .frame(width: 26, height: 26)
            if done {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
            } else {
                Text("\(index)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: done)
    }
}

// MARK: - Code snippet with copy button

private struct CodeSnippet: View {
    let text: String
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption)
                    .foregroundStyle(copied ? .green : .secondary)
            }
            .buttonStyle(.plain)
            .help("Copy")
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
    }
}
