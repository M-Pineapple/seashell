// WaveSecretsHandlers.swift

// Pineapple 🍍
//
// Secrets and workspace MCP tool handlers:
//   wave_secret_list/set/get/delete  — Tier C, delegate to helper (wsh secret …)
//   wave_create_fish_widget          — Tier B, convenience wrapper around wave_create_widget
//   wave_bootstrap_workspace         — Tier B, creates a full dev environment in a Wave tab

import Foundation
import MCP
import Logging

// MARK: - wave_secret_list

/// List Wave secret keys (Tier C — requires approved=true + reason).
func handleWaveSecretList(
    params: CallTool.Parameters,
    logger: Logger,
    config: Configuration
) async -> CallTool.Result {
    guard let arguments = params.arguments else {
        return .init(content: [.text("Missing required parameters")], isError: true)
    }

    // Tier C confirmation
    guard PermissionGuard.isApprovedWithReason(arguments) else {
        return .init(content: [.text(PermissionGuard.approvalMessage(
            for: "wave_secret_list",
            action: "List all Wave secret keys"
        ))])
    }

    guard await sharedWaveHelperClient.isConnected() else {
        return helperRequiredResult(toolName: "wave_secret_list")
    }

    do {
        let result = try await sharedWaveHelperClient.secretList()
        if let arr = result.arrayValue {
            let keys = arr.compactMap { $0.stringValue }
            if keys.isEmpty {
                return .init(content: [.text("No Wave secrets configured.")])
            }
            return .init(content: [.text("Wave secrets (\(keys.count) keys):\n\n" + keys.map { "  • \($0)" }.joined(separator: "\n"))])
        }
        return .init(content: [.text("Wave secrets:\n\n\(phase3ResultJSON(result))")])
    } catch {
        return .init(content: [.text("Error listing Wave secrets: \(error.localizedDescription)")], isError: true)
    }
}

// MARK: - wave_secret_set

/// Set a Wave secret (Tier C — requires approved=true + reason).
func handleWaveSecretSet(
    params: CallTool.Parameters,
    logger: Logger,
    config: Configuration
) async -> CallTool.Result {
    guard let arguments = params.arguments else {
        return .init(content: [.text("Missing required parameters")], isError: true)
    }

    guard let keyValue = arguments["key"], case .string(let key) = keyValue, !key.isEmpty else {
        return .init(content: [.text("Missing required parameter: key")], isError: true)
    }

    guard let valValue = arguments["value"], case .string(let value) = valValue else {
        return .init(content: [.text("Missing required parameter: value")], isError: true)
    }

    // Tier C confirmation
    guard PermissionGuard.isApprovedWithReason(arguments) else {
        return .init(content: [.text(PermissionGuard.approvalMessage(
            for: "wave_secret_set",
            action: "Set Wave secret '\(key)'"
        ))])
    }

    guard await sharedWaveHelperClient.isConnected() else {
        return helperRequiredResult(toolName: "wave_secret_set")
    }

    do {
        _ = try await sharedWaveHelperClient.secretSet(key: key, value: value)
        logger.info("Wave secret set: \(key)")
        return .init(content: [.text("✓ Wave secret '\(key)' set.")])
    } catch {
        return .init(content: [.text("Error setting Wave secret: \(error.localizedDescription)")], isError: true)
    }
}

// MARK: - wave_secret_get

/// Get a Wave secret value (Tier C — requires approved=true + reason).
func handleWaveSecretGet(
    params: CallTool.Parameters,
    logger: Logger,
    config: Configuration
) async -> CallTool.Result {
    guard let arguments = params.arguments else {
        return .init(content: [.text("Missing required parameters")], isError: true)
    }

    guard let keyValue = arguments["key"], case .string(let key) = keyValue, !key.isEmpty else {
        return .init(content: [.text("Missing required parameter: key")], isError: true)
    }

    // Tier C confirmation
    guard PermissionGuard.isApprovedWithReason(arguments) else {
        return .init(content: [.text(PermissionGuard.approvalMessage(
            for: "wave_secret_get",
            action: "Read Wave secret '\(key)'"
        ))])
    }

    guard await sharedWaveHelperClient.isConnected() else {
        return helperRequiredResult(toolName: "wave_secret_get")
    }

    do {
        let result = try await sharedWaveHelperClient.secretGet(key: key)
        guard PermissionGuard.allowSecretRead else {
            return .init(content: [.text("Wave secret '\(key)' exists. Value withheld.")])
        }
        if let secretValue = result.dictValue?["value"]?.stringValue {
            return .init(content: [.text("Wave secret '\(key)':\n\n\(secretValue)")])
        }
        return .init(content: [.text("Wave secret '\(key)':\n\n\(phase3ResultJSON(result))")])
    } catch {
        return .init(content: [.text("Error getting Wave secret: \(error.localizedDescription)")], isError: true)
    }
}

// MARK: - wave_secret_delete

/// Delete a Wave secret (Tier C — requires approved=true + reason).
func handleWaveSecretDelete(
    params: CallTool.Parameters,
    logger: Logger,
    config: Configuration
) async -> CallTool.Result {
    guard let arguments = params.arguments else {
        return .init(content: [.text("Missing required parameters")], isError: true)
    }

    guard let keyValue = arguments["key"], case .string(let key) = keyValue, !key.isEmpty else {
        return .init(content: [.text("Missing required parameter: key")], isError: true)
    }

    // Tier C confirmation
    guard PermissionGuard.isApprovedWithReason(arguments) else {
        return .init(content: [.text(PermissionGuard.approvalMessage(
            for: "wave_secret_delete",
            action: "Delete Wave secret '\(key)'"
        ))])
    }

    guard await sharedWaveHelperClient.isConnected() else {
        return helperRequiredResult(toolName: "wave_secret_delete")
    }

    do {
        _ = try await sharedWaveHelperClient.secretDelete(key: key)
        logger.info("Wave secret deleted: \(key)")
        return .init(content: [.text("✓ Wave secret '\(key)' deleted.")])
    } catch {
        return .init(content: [.text("Error deleting Wave secret: \(error.localizedDescription)")], isError: true)
    }
}

// MARK: - wave_create_fish_widget

/// Convenience tool: add a Fish shell widget to the Wave widget bar (Tier B).
/// Equivalent to wave_create_widget with fish-shell blockdef pre-filled.
func handleWaveCreateFishWidget(
    params: CallTool.Parameters,
    logger: Logger,
    config: Configuration
) async -> CallTool.Result {
    let arguments = params.arguments ?? [:]

    // Optional overrides
    let id         = arguments["id"]?.stringValue    ?? "fish-shell"
    let label      = arguments["label"]?.stringValue ?? "Fish"
    let icon       = arguments["icon"]?.stringValue  ?? "terminal"
    let cwd        = arguments["cwd"]?.stringValue

    // Tier B confirmation
    if !PermissionGuard.isApproved(arguments) {
        return .init(content: [.text(PermissionGuard.confirmationMessage(
            for: "wave_create_fish_widget",
            action: "Add Fish shell widget '\(id)' to Wave widget bar",
            targetFile: "~/.waveterm/widgets.json"
        ))])
    }

    let waveManager = makeWaveManager(config)

    guard await waveManager.waveIsInstalled() else {
        return .init(
            content: [.text(WaveConfigError.notInstalled(config.wave.configDir).errorDescription ?? "")],
            isError: true
        )
    }

    // Build the widget config
    var meta: [String: AnyCodableValue] = [
        "view":           .string("term"),
        "controller":     .string("cmd"),
        "cmd":            .string("fish"),
        "cmd:runonstart": .bool(true),
    ]
    if let cwd { meta["cmd:cwd"] = .string(cwd) }

    let blockDef = BlockDef(meta: meta)
    let widget = WidgetConfig(
        blockdef:    blockDef,
        icon:        icon,
        label:       label,
        description: "Fish interactive shell"
    )

    do {
        try await waveManager.writeWidget(id: id, config: widget)
        logger.info("Fish widget created: \(id)")
        return .init(content: [.text("✓ Fish shell widget '\(id)' added to Wave widget bar.\n\nRestart Wave or refresh the widget bar to see it.")])
    } catch {
        return .init(content: [.text("Error creating Fish widget: \(error.localizedDescription)")], isError: true)
    }
}

// MARK: - wave_bootstrap_workspace

/// Bootstrap a Wave tab with a project-specific block layout (Tier B).
/// Templates: general, python-dev, node-dev, swift-dev.
func handleWaveBootstrapWorkspace(
    params: CallTool.Parameters,
    logger: Logger,
    config: Configuration
) async -> CallTool.Result {
    guard let arguments = params.arguments else {
        return .init(content: [.text("Missing required parameters")], isError: true)
    }

    guard let tabIdValue = arguments["tab_id"], case .string(let tabId) = tabIdValue, !tabId.isEmpty else {
        return .init(content: [.text("Missing required parameter: tab_id")], isError: true)
    }

    let template = arguments["template"]?.stringValue ?? "general"
    let cwd      = arguments["cwd"]?.stringValue

    // Tier B confirmation
    if !PermissionGuard.isApproved(arguments) {
        return .init(content: [.text(PermissionGuard.confirmationMessage(
            for: "wave_bootstrap_workspace",
            action: "Bootstrap '\(template)' workspace in tab '\(tabId)'" + (cwd.map { " (cwd: \($0))" } ?? ""),
            targetFile: "Wave Terminal (live blocks)"
        ))])
    }

    guard await sharedWaveHelperClient.isConnected() else {
        return helperRequiredResult(toolName: "wave_bootstrap_workspace")
    }

    let plan = workspacePlan(template: template, tabId: tabId, cwd: cwd)
    if plan.isEmpty {
        return .init(
            content: [.text("Unknown template '\(template)'. Valid templates: general, python-dev, node-dev, swift-dev")],
            isError: true
        )
    }

    var created: [(label: String, blockId: String)] = []
    var errors:  [String] = []

    for step in plan {
        do {
            let result = try await sharedWaveHelperClient.createBlock(tabId: tabId, meta: step.meta)
            let blockId = result.dictValue?["block_id"]?.stringValue ?? "unknown"
            created.append((label: step.label, blockId: blockId))
            logger.info("Bootstrap block created: \(step.label) (\(blockId))")
        } catch {
            errors.append("\(step.label): \(error.localizedDescription)")
        }
    }

    var lines: [String] = ["✓ Workspace bootstrapped with '\(template)' template in tab '\(tabId)'.\n"]
    lines += created.map { "  • \($0.label) → block \($0.blockId)" }
    if !errors.isEmpty {
        lines.append("\nErrors:")
        lines += errors.map { "  ✗ \($0)" }
    }
    return .init(content: [.text(lines.joined(separator: "\n"))])
}

// MARK: - Bootstrap workspace plan

private struct BlockStep {
    let label: String
    let meta:  [String: AnyCodableValue]
}

private func workspacePlan(template: String, tabId: String, cwd: String?) -> [BlockStep] {
    var baseMeta: [String: AnyCodableValue] = [
        "view":           .string("term"),
        "controller":     .string("cmd"),
        "cmd:runonstart": .bool(true),
    ]
    if let cwd { baseMeta["cmd:cwd"] = .string(cwd) }

    func termBlock(label: String, cmd: String, extraCwd: String? = nil) -> BlockStep {
        var m = baseMeta
        m["cmd"] = .string(cmd)
        if let ec = extraCwd { m["cmd:cwd"] = .string(ec) }
        return BlockStep(label: label, meta: m)
    }

    func previewBlock(file: String) -> BlockStep {
        var m: [String: AnyCodableValue] = ["view": .string("preview"), "file": .string(file)]
        return BlockStep(label: "Preview: \(file)", meta: m)
    }

    switch template {
    case "general":
        return [
            termBlock(label: "Shell", cmd: "$SHELL"),
        ]

    case "python-dev":
        return [
            termBlock(label: "Python REPL",  cmd: "python3"),
            termBlock(label: "Shell",         cmd: "$SHELL"),
        ]

    case "node-dev":
        return [
            termBlock(label: "Node REPL", cmd: "node"),
            termBlock(label: "Shell",     cmd: "$SHELL"),
        ]

    case "swift-dev":
        return [
            termBlock(label: "Swift REPL", cmd: "swift repl"),
            termBlock(label: "Shell",      cmd: "$SHELL"),
        ]

    default:
        return []
    }
}

// MARK: - Shared helpers

private func helperRequiredResult(toolName: String) -> CallTool.Result {
    return .init(content: [.text("""
        ⚠️  Wave helper block is not connected.

        Secret operations (\(toolName)) require the Seashell Helper running inside Wave Terminal.

        To start it:
        1. Open Wave Terminal
        2. Click the "Seashell Helper" widget in the widget bar
        3. Wait for "Ready to proxy Wave RPC requests" to appear
        4. Try this tool again
        """)], isError: true)
}

private func phase3ResultJSON(_ value: AnyCodableValue) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(value),
          let str = String(data: data, encoding: .utf8) else {
        return String(describing: value)
    }
    return str
}

