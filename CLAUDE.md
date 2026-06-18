# ContextVault — Agent Brief

## Concept
App Mac native menubar (Swift/SwiftUI) servant de mémoire persistante par projet pour les agents AI (Claude Code, Cursor, Codex, Windsurf…).
Expose un serveur MCP que tout agent compatible MCP découvre via auto-discovery. Stockage : fichiers Markdown locaux.

**Problème résolu** : chaque agent AI rescanne le codebase à chaque session → gaspillage de tokens.
ContextVault donne à l'agent une mémoire structurée par projet (architecture, décisions, contexte, TODO).

---

## Environnement Xcode — points critiques

| Setting | Valeur | Impact |
|---|---|---|
| Xcode | 26.5 | `PBXFileSystemSynchronizedRootGroup` actif |
| macOS deployment target | 26.4 | APIs modernes OK |
| `SWIFT_DEFAULT_ACTOR_ISOLATION` | `MainActor` | Tout le code est `@MainActor` par défaut |
| `SWIFT_APPROACHABLE_CONCURRENCY` | YES | Concurrence structurée obligatoire |
| `ENABLE_APP_SANDBOX` | YES → à désactiver | Voir contraintes sandbox ci-dessous |
| Bundle ID | `Magnus.ContextVault` | — |

**`PBXFileSystemSynchronizedRootGroup`** : tout fichier `.swift` créé dans `ContextVault/` ou ses sous-dossiers est **automatiquement compilé** par Xcode. Pas besoin de toucher le `.pbxproj`.

**Sandbox** : `ENABLE_APP_SANDBOX = YES` par défaut. Pour écrire dans `~/.contextvault/` et `~/.config/claude/ide/`, le sandbox doit être **désactivé** dans les build settings du target (`ENABLE_APP_SANDBOX = NO`). Acceptable pour un outil développeur distribué hors App Store.

---

## Structure de fichiers cible

```
ContextVault/                          ← tout fichier .swift ici se compile automatiquement
├── App/
│   └── ContextVaultApp.swift          ← @main, MenuBarExtra, Window
├── Models/
│   ├── Project.swift                 ← struct Project : Identifiable, Codable
│   └── Note.swift                    ← struct Note : Identifiable, Codable
├── Vault/
│   └── VaultManager.swift            ← @Observable, CRUD Markdown sur disque
├── MCP/
│   ├── MCPServer.swift               ← serveur WebSocket (Claude Code), port 9876
│   ├── MCPHTTPServer.swift           ← serveur HTTP/SSE (Claude Desktop), port 9877
│   ├── MCPTools.swift                ← implémentation des 5 outils MCP
│   └── AutoDiscovery.swift           ← écrit/supprime ~/.config/claude/ide/contextvault.lock
├── UI/
│   ├── MainWindowView.swift          ← NavigationSplitView 3 colonnes
│   ├── ProjectListView.swift         ← liste projets + bouton ajout
│   ├── NoteListView.swift            ← liste notes du projet sélectionné
│   ├── NoteEditorView.swift          ← éditeur Markdown (TextEditor) + rendu Markdown
│   ├── MenuBarView.swift             ← menu menubar (statut, switcher projet)
│   └── AddProjectView.swift          ← sheet ajout projet (nom + path picker)
└── Assets.xcassets/
    └── AppIcon.appiconset/
        └── icon_1024.png             ← source icône (à déposer, puis make icons)

ContextVaultTests/
├── VaultManagerTests.swift           ← tests CRUD notes (priorité haute)
└── MCPToolsTests.swift               ← tests outils MCP

À SUPPRIMER (boilerplate Xcode) :
- ContextVault/Item.swift
- ContextVault/ContentView.swift       ← remplacé par UI/MainWindowView.swift
```

---

## Stockage sur disque

```
~/.contextvault/
└── <project-slug>/
    ├── .project.json          ← { id, name, rootPath, createdAt }
    └── notes/
        ├── architecture.md
        ├── decisions.md
        └── context.md
```

Chaque note Markdown a un frontmatter YAML :
```markdown
---
title: Architecture
tags: [backend, mcp]
updatedAt: 2026-06-12T10:00:00Z
---

Contenu de la note...
```

Les liens entre notes style Obsidian (`[[Titre]]`) sont supportés dans l'éditeur (rendu + navigation).
`project-slug` = nom en kebab-case, ex. `claude-vault`.

---

## Protocole MCP

### Transport WebSocket (Claude Code) — port 9876
JSON-RPC 2.0 sur WebSocket. Auto-discovery via fichier lock.

### Transport HTTP/SSE (Claude Desktop) — port 9877
- `POST /message` → reçoit JSON-RPC, retourne JSON
- `GET /sse` → stream SSE pour notifications serveur→client

### Auto-discovery
Fichier `~/.config/claude/ide/contextvault.lock` :
```json
{ "pid": 12345, "wsPort": 9876, "httpPort": 9877, "version": "1.0" }
```
Créé au démarrage, supprimé à l'arrêt (proprement, même sur crash via signal handler).

### Outils exposés

| Outil | Params | Retour |
|---|---|---|
| `get_project_context` | `path: String` | Contexte du projet dont `rootPath` est préfixe de `path` |
| `list_notes` | `project: String` | Titres + tags + updatedAt de toutes les notes |
| `read_note` | `project: String, title: String` | Contenu complet (frontmatter + body) |
| `write_note` | `project: String, title: String, body: String, tags?: [String]` | Crée ou met à jour |
| `search_notes` | `project: String, query: String` | Recherche full-text (titre + corps + tags) |

`project` = slug du projet.

---

## Architecture app

### Entry point
```swift
@main
struct ContextVaultApp: App {
    @State private var vault = VaultManager()
    @State private var mcpServer = MCPServer()

    var body: some Scene {
        MenuBarExtra("ContextVault", systemImage: "brain") {
            MenuBarView()
        }
        Window("ContextVault", id: "main") {
            MainWindowView()
        }
        .environment(vault)
        .environment(mcpServer)
    }
}
```

### État partagé
- `VaultManager` (`@Observable`) — source de vérité, injecté via `.environment()`
- `MCPServer` (`@Observable`) — statut connexion, clients connectés, tokens estimés
- Pas de SwiftData, pas de CoreData, pas de UserDefaults pour les données métier

### Concurrence
- Serveurs MCP tournent dans des `Task { }` en background (Network.framework callbacks)
- Mises à jour UI : `await MainActor.run { }` ou `@MainActor` explicite
- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` : classes sans annotation → implicitement MainActor

---

## Implémentation WebSocket

Network.framework uniquement (pas de dépendance externe). Handshake + framing manuel :

1. **Handshake** : lire requête TCP, extraire `Sec-WebSocket-Key`, répondre `101 Switching Protocols` avec `Sec-WebSocket-Accept = base64(SHA1(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))`
2. **Parsing frames** : FIN/opcode/mask/length, XOR payload × masking key (client→serveur toujours masqué)
3. **Encoding frames** : non masqué côté serveur
4. **Opcodes** : `0x1` text, `0x8` close, `0x9` ping → répondre pong `0xA`

SHA1 via `CryptoKit.Insecure.SHA1.hash(data:)`.

---

## UI — Design Apple natif macOS

Référence : Notes.app, Xcode, Mail, Finder. Pas d'UI custom — 100% composants natifs SwiftUI macOS.

### Patterns Apple à respecter

**Navigation**
- `NavigationSplitView` 3 colonnes (sidebar projets | liste notes | éditeur) — comme Mail/Notes
- Sidebar avec `List` + `Label` (SF Symbols), sélection `.listStyle(.sidebar)`
- Toolbar native `ToolbarItem` avec boutons SF Symbols — pas de boutons custom flottants

**Typographie**
- Titres : `.title2` `.headline` — jamais de font custom
- Corps : `.body` avec `.foregroundStyle(.primary / .secondary / .tertiary)`
- Metadata (date, tags) : `.caption` `.foregroundStyle(.secondary)`

**Couleurs**
- Exclusivement sémantiques : `.primary`, `.secondary`, `.accent`, `.background`, `.groupedBackground`
- Jamais de hex hardcodé — respecter dark mode automatiquement

**Composants**
- `List` avec `Section` pour grouper les notes par catégorie
- `Form` + `LabeledContent` pour les settings projet
- `.searchable(text:)` sur la liste de notes — barre recherche native en haut
- Tags : `FlowLayout` de chips avec `.background(.quaternary, in: Capsule())`
- Toolbar split-view : bouton `⊕` pour nouvelle note, `⌘F` pour focus search

**Éditeur Markdown**
- `TextEditor` plein écran avec padding `.contentMargins`
- Toolbar format : Bold / Italic / Code via `ToolbarItemGroup(placement: .automatic)`
- Toggle "Preview" (rendu Markdown) dans toolbar — `AttributedString` via `try AttributedString(markdown:)`

**MenuBarExtra**
- Style `.window` (popover natif, pas `.menu`)
- Contenu : statut connexion avec `Label` + indicateur vert/orange/rouge (Circle SF Symbol)
- Liste des projets récents avec `Divider()` + "Open ContextVault..." en bas
- Indicateur tokens économisés : `Text` avec `.monospacedDigit()`

**Animations & transitions**
- `.animation(.spring(), value:)` pour les changements de sélection
- `.transition(.move(edge: .trailing))` pour l'apparition de l'éditeur
- Pas d'animations custom — uniquement celles proposées par SwiftUI

**Fenêtre principale**
- `.windowStyle(.titleBar)` avec `unified` toolbar (titre + toolbar fusionnés comme Xcode)
- `.windowToolbarStyle(.unified(showsTitle: true))`
- Taille minimale : 900×600, idéale : 1200×800

### Hiérarchie visuelle cible
```
┌─────────────────────────────────────────────────────┐
│ ⬡ ContextVault    [+ Note]  [⌘F]          [● Live]  │  ← toolbar unifiée
├──────────┬────────────────┬────────────────────────┤
│ PROJETS  │ Notes          │                        │
│          │ ──────────     │  # Architecture        │
│ ● MyApp  │ Architecture   │                        │
│   Vault  │ Decisions      │  Contenu de la note    │
│   API    │ Context        │  en Markdown...        │
│          │                │                        │
│ [+ Proj] │ 🔍 Rechercher  │  [[Decisions]]         │
└──────────┴────────────────┴────────────────────────┘
```

---

## État actuel

| Fichier | État |
|---|---|
| `ContextVaultApp.swift` | Boilerplate SwiftData → **à remplacer** |
| `ContentView.swift` | Boilerplate → **à supprimer** |
| `Item.swift` | Boilerplate SwiftData → **à supprimer** |
| `Makefile` | Configuré (`make build/dmg/icons/clean`) |
| `.gitignore` | Configuré |
| Aucun fichier MCP/Vault/UI | **Tout est à créer** |

---

## Priorités MVP

1. `Models/Project.swift` + `Models/Note.swift`
2. `Vault/VaultManager.swift` (CRUD + search + parse frontmatter)
3. `MCP/MCPTools.swift` + `MCP/MCPServer.swift` (WebSocket)
4. `MCP/AutoDiscovery.swift`
5. `App/ContextVaultApp.swift` (MenuBarExtra + Window)
6. `UI/MenuBarView.swift`
7. `UI/MainWindowView.swift` + sous-vues
8. `MCP/MCPHTTPServer.swift` (Claude Desktop)

---

## Conventions

- **Pas de SwiftData, pas de CoreData** — tout sur disque en Markdown
- **Pas de dépendances externes** — Network.framework + CryptoKit uniquement
- Nommage : `PascalCase` types, `camelCase` méthodes, un fichier = un type principal
- Pas de commentaires sauf si comportement non-évident
- `@Observable` pour les classes injectées dans l'environnement SwiftUI
- Désactiver `ENABLE_APP_SANDBOX` dans les build settings pour les accès fichiers

---

## Build

```bash
make build    # Release via xcodebuild
make dmg      # DMG dans dist/ (create-dmg installé ✓)
make icons    # Génère icônes depuis ContextVault/Assets.xcassets/AppIcon.appiconset/icon_1024.png
make clean    # Supprime .build/
```
