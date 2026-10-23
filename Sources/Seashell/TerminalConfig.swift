import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Terminal configuration and detection
public struct TerminalConfig {
    public enum TerminalType: String, CaseIterable {
        case iterm2 = "iTerm"
        case terminal = "Terminal"
        case alacritty = "Alacritty"
        case wave = "Wave"
    }

    /// Detect which terminals are installed
    public static func detectInstalledTerminals() -> [TerminalType] {
        #if !canImport(AppKit)
        return []
        #else
        var installed: [TerminalType] = []
        let workspace = NSWorkspace.shared

        for terminal in TerminalType.allCases {
            let bundleIds = getBundleIdentifiers(for: terminal)
            if bundleIds.contains(where: { workspace.urlForApplication(withBundleIdentifier: $0) != nil }) {
                installed.append(terminal)
            }
        }

        return installed
        #endif
    }

    /// Get the preferred terminal from config or auto-detect
    public static func getPreferredTerminal() -> TerminalType {
        // TODO: Read from config file first

        // Auto-detect in order of preference (Wave first as primary terminal)
        let preferences: [TerminalType] = [.wave, .iterm2, .terminal]
        let installed = detectInstalledTerminals()

        for preference in preferences {
            if installed.contains(preference) {
                return preference
            }
        }

        // Fallback to Terminal.app
        return .terminal
    }

    /// Get possible bundle identifiers for terminal type
    public static func getBundleIdentifiers(for terminal: TerminalType) -> [String] {
        switch terminal {
        case .iterm2:
            return ["com.googlecode.iterm2"]
        case .terminal:
            return ["com.apple.Terminal"]
        case .alacritty:
            return ["org.alacritty"]
        case .wave:
            return ["dev.waveterm.Wave", "dev.waveterm"]
        }
    }

    /// Get primary bundle identifier for terminal type
    public static func getBundleIdentifier(for terminal: TerminalType) -> String {
        return getBundleIdentifiers(for: terminal).first ?? ""
    }
}
