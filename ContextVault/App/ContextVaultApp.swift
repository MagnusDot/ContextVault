import SwiftUI
import AppKit

@main
struct ContextVaultApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var vault = VaultManager()
    @State private var mcp = MCPServer()
    @State private var rag = CodeRAGManager.shared
    var body: some Scene {
        WindowGroup("ContextVault", id: "main") {
            MainWindowView()
                .environment(vault)
                .environment(mcp)
                .environment(rag)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1200, height: 800)
        .defaultPosition(.center)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        MenuBarExtra {
            MenuBarView()
                .environment(vault)
                .environment(mcp)
                .task { mcp.start(vault: vault) }
        } label: {
            MenuBarIconView(isConnected: mcp.connectedClients > 0, isRunning: mcp.isRunning)
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Menubar icon

private struct MenuBarIconView: View {
    let isConnected: Bool
    let isRunning: Bool

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "brain")
            if isConnected {
                Circle()
                    .fill(Color.green)
                    .frame(width: 5, height: 5)
                    .offset(y: -4)
            }
        }
    }
}
