import Foundation
import Logging

/// Shared terminal utilities

/// Create AppleScript for different terminal types
func createAppleScript(for terminal: TerminalConfig.TerminalType, command: String) -> String {
    switch terminal {
    case .iterm2:
        // Create a new session (tab) for each command
        return """
        tell application "iTerm"
            activate

            if (count of windows) = 0 then
                create window with default profile
            else
                -- Create new tab in current window for isolation
                tell current window
                    create tab with default profile
                end tell
            end if

            tell current window
                tell current session
                    write text "\(command)"
                end tell
            end tell
        end tell
        """

    case .terminal:
        // Always open a new tab for command isolation
        return """
        tell application "Terminal"
            activate

            if (count of windows) = 0 then
                do script "\(command)"
            else
                -- Open new tab in frontmost window
                tell application "System Events"
                    tell process "Terminal"
                        click menu item "New Tab" of menu "Shell" of menu bar 1
                    end tell
                end tell
                delay 0.5
                do script "\(command)" in front window
            end if
        end tell
        """

    case .alacritty:
        // Alacritty doesn't support tabs natively; use keyboard events
        return """
        tell application "Alacritty" to activate
        delay 1.0
        tell application "System Events"
            keystroke "\(command)"
            delay 0.2
            keystroke return
        end tell
        """

    case .wave:
        // Wave Terminal — not used for execute_command (routed through executeWaveCommand instead)
        // This fallback activates Wave and types into the active block
        return """
        tell application "Wave" to activate
        delay 0.3
        tell application "System Events"
            keystroke "\(command)"
            delay 0.2
            keystroke return
        end tell
        """
    }
}

/// Execute a command directly for Wave Terminal using Process (no AppleScript needed).
/// Runs the command via Process, capturing output to temp files.
/// Synchronous execution — no GCD, no continuations. Simple and reliable.
/// Returns (success: Bool, output: String, exitCode: Int32)
func executeWaveCommand(command: String, commandId: String, workingDirectory: String?, logger: Logging.Logger) -> (Bool, String, Int32) {
    let outputFile = "\(SeashellTemp.dir)/seashell_output_\(commandId).json"
    let stdoutFile = "\(SeashellTemp.dir)/seashell_stdout_\(commandId).txt"
    let stderrFile = "\(SeashellTemp.dir)/seashell_stderr_\(commandId).txt"

    // Build shell command that redirects output to files
    let cdPrefix = workingDirectory.map { "cd \"\($0)\" && " } ?? ""
    let shellCommand = "\(cdPrefix)(\(command)) > \"\(stdoutFile)\" 2> \"\(stderrFile)\""

    logger.info("Wave execute (sync): \(shellCommand)")

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", shellCommand]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice

    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return (false, "Failed to launch process: \(error.localizedDescription)", -1)
    }

    let exitCode = process.terminationStatus
    let stdout = (try? String(contentsOfFile: stdoutFile, encoding: .utf8)) ?? ""
    let stderr = (try? String(contentsOfFile: stderrFile, encoding: .utf8)) ?? ""

    // Clean up temp files
    try? FileManager.default.removeItem(atPath: stdoutFile)
    try? FileManager.default.removeItem(atPath: stderrFile)

    // Write JSON result file
    let result: [String: Any] = [
        "commandId": commandId,
        "command": command,
        "output": stdout,
        "error": stderr,
        "exitCode": exitCode,
        "timestamp": ISO8601DateFormatter().string(from: Date())
    ]
    if let jsonData = try? JSONSerialization.data(withJSONObject: result, options: .prettyPrinted) {
        try? jsonData.write(to: URL(fileURLWithPath: outputFile))
        FileManager.default.createFile(atPath: "\(outputFile).complete", contents: nil)
    }

    let combinedOutput = stderr.isEmpty ? stdout : "\(stdout)\n\(stderr)"
    return (exitCode == 0, combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines), exitCode)
}

/// Create output capture script
func createOutputCaptureScript(command: String, commandId: String) -> String {
    let outputFile = "\(SeashellTemp.dir)/seashell_output_\(commandId).json"

    return """
    #!/bin/bash
    umask 077

    # Command to execute
    COMMAND='\(command.replacingOccurrences(of: "'", with: "'\"'\"'"))'

    # Create a temporary file for stderr
    STDERR_FILE="\(SeashellTemp.dir)/seashell_stderr_\(commandId).tmp"

    # Execute command and capture output
    OUTPUT=$(eval "$COMMAND" 2>"$STDERR_FILE")
    EXIT_CODE=$?

    # Read stderr
    STDERR=$(<"$STDERR_FILE")
    rm -f "$STDERR_FILE"

    # Escape JSON strings
    escape_json() {
        python3 -c "import sys, json; print(json.dumps(sys.stdin.read()))" | sed 's/^"//;s/"$//'
    }

    # Create JSON result
    cat > "\(outputFile)" << EOF
    {
        "commandId": "\(commandId)",
        "command": "$(echo "$COMMAND" | escape_json)",
        "output": "$(echo "$OUTPUT" | escape_json)",
        "error": "$(echo "$STDERR" | escape_json)",
        "exitCode": $EXIT_CODE,
        "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    }
    EOF

    # Signal completion by creating a marker file
    touch "\(outputFile).complete"

    # Also echo the output for immediate viewing in terminal
    echo "$OUTPUT"
    if [ -n "$STDERR" ]; then
        echo "$STDERR" >&2
    fi

    exit $EXIT_CODE
    """
}
