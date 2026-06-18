import Foundation
@testable import ContextVault

// Realistic seed data representing a medium-sized Swift project.
// Used across test suites to simulate real agent workflows.
enum SeedData {

    // MARK: - Project

    static let project = Project(
        id: UUID(uuidString: "A1B2C3D4-E5F6-7890-ABCD-EF1234567890")!,
        name: "MyApp",
        rootPath: "/Users/dev/projects/my-app",
        createdAt: Date(timeIntervalSince1970: 1_718_000_000)
    )

    // MARK: - Notes

    static let contextNote = Note(
        id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        title: "context",
        body: """
        ## Current state
        - MCP server running on :9876 (WebSocket) and :9877 (HTTP/SSE)
        - Auth module rewritten — JWT now stateless, Redis session store removed
        - Bug: refresh token rotation fails when concurrent requests race (GH-412)

        ## Last session
        Fixed the WebSocket handshake for Safari clients (Sec-WebSocket-Key parsing).
        Added exponential backoff to API retry logic in NetworkClient.swift.

        ## Next steps
        1. Fix GH-412 — add optimistic locking to token rotation
        2. Write migration for users table (add `device_fingerprint` column)
        3. Deploy to staging before Thursday
        """,
        tags: ["context"],
        updatedAt: Date(timeIntervalSince1970: 1_718_100_000),
        projectSlug: project.slug
    )

    static let architectureNote = Note(
        id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
        title: "architecture",
        body: """
        ## Overview
        Three-tier: iOS client → API gateway (Go) → services (Swift/Vapor).

        ## Key components
        - **AuthService** — JWT HS256, 15-min access token, 7-day refresh
        - **NetworkClient** — URLSession-based, retry with exponential backoff (3 attempts)
        - **SyncEngine** — background actor, merges server diffs into local CoreData store
        - **MCPServer** — WebSocket :9876 (Claude Code), HTTP/SSE :9877 (Claude Desktop)

        ## Data flow
        Request → AuthMiddleware → RouteHandler → Repository → Database (Postgres 16)
        Background sync: SyncEngine polls every 30s, applies CRDTs for conflict resolution.

        ## Constraints
        - All API calls must complete in < 2s (p99 SLA)
        - Zero external dependencies in the iOS client (Network.framework only)
        - CoreData migrations must be backwards-compatible for 2 major versions
        """,
        tags: ["architecture"],
        updatedAt: Date(timeIntervalSince1970: 1_718_050_000),
        projectSlug: project.slug
    )

    static let decisionsNote = Note(
        id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
        title: "decisions",
        body: """
        ## JWT over sessions
        Chose stateless JWT to avoid Redis ops on every request.
        Trade-off: token revocation requires a short-lived blocklist (< 15 min window).

        ## CoreData over SwiftData
        SwiftData migration APIs unstable as of Xcode 26.3. CoreData battle-tested.
        Will revisit in 12 months when SwiftData matures.

        ## Go API gateway
        Swift on server (Vapor) initially considered but Go has better HTTP/2 tooling.
        Auth, rate-limiting, and routing handled in Go; business logic in Swift services.

        ## Postgres over SQLite
        Concurrent writes from multiple service replicas require Postgres MVCC.
        SQLite only in the iOS client (via CoreData).
        """,
        tags: ["decisions"],
        updatedAt: Date(timeIntervalSince1970: 1_718_020_000),
        projectSlug: project.slug
    )

    static var allNotes: [Note] { [contextNote, architectureNote, decisionsNote] }

    // MARK: - Fake codebase files (simulate what the agent would read without ContextVault)

    // Each entry: (filename, approximate line count, average chars/line)
    static let fakeCodebaseFiles: [(name: String, lines: Int, charsPerLine: Int)] = [
        ("AuthService.swift",      320, 52),
        ("NetworkClient.swift",    180, 48),
        ("SyncEngine.swift",       410, 55),
        ("UserRepository.swift",   140, 45),
        ("RouteHandler.swift",     200, 50),
        ("CoreDataStack.swift",    160, 47),
        ("MCPServer.swift",        380, 54),
        ("JWTMiddleware.go",       120, 46),
        ("APIGateway.go",          290, 51),
        ("migrations/0042.sql",     80, 40),
        ("tests/AuthTests.swift",  190, 50),
        ("Package.swift",           45, 38),
        ("README.md",              120, 60),
        ("config/staging.yaml",     60, 35),
        ("config/prod.yaml",        60, 35),
    ]

    // Total tokens if agent reads all files to understand the project (chars / 4)
    static var fullReadTokenCost: Int {
        fakeCodebaseFiles.reduce(0) { $0 + ($1.lines * $1.charsPerLine) } / 4
    }

    // MARK: - Helpers

    static func seedVault(_ vault: VaultManager) throws {
        try vault.addProject(project)
        for note in allNotes {
            try vault.writeNote(note, to: project)
        }
    }
}
