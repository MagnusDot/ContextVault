import Testing
@testable import ContextVault

// Entry point for the ContextVault test suite.
// Tests are organized across separate files by component:
//   VaultManagerTests      — CRUD, search, disk persistence
//   MCPToolsTests          — all 10 MCP tools end-to-end
//   SmartCrusherTests      — JSON → columnar table compression
//   ResponseCompressorTests — log/markdown/JSON compression + CCR offload
//   TokenSavingsTests      — savings tracking + economic claims
