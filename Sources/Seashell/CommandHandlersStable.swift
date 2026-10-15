import Foundation
import Darwin
import MCP
import Logging

/// Version of execute command without background monitoring to prevent server crashes
func handleExecuteCommandV2NoMonitoring(params: CallTool.Parameters, logger: Logger, config: Configuration) async throws -> CallTool.Result {
    guard let arguments = params.arguments,
          let command = arguments["command"],
          case .string(let commandString) = command else {
        return CallTool.Result(
            content: [.text("Missing or invalid 'command' parameter")],
            isError: true
        )
    }
    
    var workingDirectory: String?
    if let dir = arguments["working_directory"],
       case .string(let dirString) = dir {
        workingDirectory = dirString
    }
    
    // Generate unique command ID and record in database
    let commandId = UUID().uuidString
    logger.info("Executing command with ID: \(commandId)")
    logger.info("Command: \(commandString)")
    
    // Start database record
    let terminalType = config.getPreferredTerminal() ?? TerminalConfig.getPreferredTerminal()
    let projectId = DatabaseManager.shared.detectProjectFromDirectory(workingDirectory ?? FileManager.default.currentDirectoryPath)
    
    let commandRecord = CommandRecord(
        id: commandId,
        command: commandString,
        directory: workingDirectory,
        terminalType: terminalType.rawValue,
        projectId: projectId
    )
    
    _ = DatabaseManager.shared.saveCommand(commandRecord)
    
    // Record analytics event
    DatabaseManager.shared.recordAnalyticsEvent("command_executed", data: [
        "terminal": terminalType.rawValue,
        "has_project": projectId != nil
    ])
    
    // Security checks
    if config.isCommandBlocked(commandString) {
        logger.warning("Blocked command attempted: \(commandString)")
        return CallTool.Result(
            content: [.text("🚫 Command blocked by security policy. This command matches a blocked pattern.")],
            isError: true
        )
    }
    
    if commandString.count > config.security.maxCommandLength {
        return CallTool.Result(
            content: [.text("📏 Command too long. Maximum length: \(config.security.maxCommandLength) characters.")],
            isError: true
        )
    }
    
    // Detect preferred terminal
    let preferredTerminal = config.getPreferredTerminal() ?? TerminalConfig.getPreferredTerminal()
    logger.info("Using terminal: \(preferredTerminal.rawValue)")

    // Build the full command with working directory if needed
    var fullCommand = commandString
    if let workingDirectory = workingDirectory {
        fullCommand = "cd \"\(workingDirectory)\" && \(commandString)"
    }
    if config.isCommandBlocked(fullCommand) {
        logger.warning("Blocked command attempted: \(fullCommand)")
        return CallTool.Result(
            content: [.text("🚫 Command blocked by security policy. This command matches a blocked pattern.")],
            isError: true
        )
    }

    // ── Wave Terminal ─────────────────────────────────────────────────────────
    if preferredTerminal == .wave {

        // ── Path A: Wave helper connected + show_in_wave=true → visible block ──
        let showInWave: Bool
        if let v = arguments["show_in_wave"], case .bool(let b) = v { showInWave = b } else { showInWave = false }
        let helperConnected = await sharedWaveHelperClient.isConnected()
        if showInWave && helperConnected {
            // Append a unique sentinel so the background task knows when the
            // command finished and can parse the exit code from scrollback.
            let sentinel = "CLAUDE_DONE_\(commandId)"
            // Wrap in bash explicitly — wsh run opens in the user's default shell
            // (may be fish) which has different syntax. Escape single quotes inside.
            let escapedCmd = fullCommand.replacingOccurrences(of: "'", with: "'\\''")
            let wrappedCmd = "bash -c '(\(escapedCmd)); printf \"\\n\(sentinel)_%d\\n\" $?'"

            // wsh run -c creates a NEW terminal block in Wave that the user can see.
            // tab_id is validated by the Python helper but not forwarded to wsh;
            // wsh run opens in the currently active tab automatically.
            if let runResult = try? await sharedWaveHelperClient.runCommand(
                tabId: "active", command: wrappedCmd, cwd: workingDirectory, closeOnExit: false
            ), let blockId = runResult.dictValue?["block_id"]?.stringValue, !blockId.isEmpty {

                logger.info("Wave visible block created: \(blockId)")

                let bgCommandId = commandId
                let bgCommand   = commandString

                // Task.detached runs on Swift's global executor (NOT NIO's event loop),
                // so Task.sleep and actor awaits here don't block NIO.
                Task.detached(priority: .userInitiated) {
                    var outputLines: [String] = []
                    var exitCode: Int32 = -1
                    var found = false

                    // Poll scrollback every 500 ms for up to 60 s
                    for _ in 0..<120 {
                        try? await Task.sleep(nanoseconds: 500_000_000)

                        guard await sharedWaveHelperClient.isConnected(),
                              let scrollback = try? await sharedWaveHelperClient.getScrollback(blockId: blockId),
                              let linesVal = scrollback.dictValue?["lines"],
                              let lines = linesVal.arrayValue else { continue }

                        let strings = lines.compactMap { $0.stringValue }

                        // Sentinel line looks like "CLAUDE_DONE_<uuid>_<exitcode>"
                        if let idx = strings.lastIndex(where: { $0.hasPrefix("\(sentinel)_") }) {
                            let suffix = String(strings[idx].dropFirst("\(sentinel)_".count))
                            exitCode = Int32(suffix.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                            outputLines = Array(strings[..<idx])
                            found = true
                            break
                        }
                    }

                    let output = outputLines.joined(separator: "\n")
                    let result = CommandExecutionResult(
                        commandId: bgCommandId,
                        command:   bgCommand,
                        output:    output,
                        error:     "",
                        exitCode:  found ? exitCode : -1,
                        timestamp: Date()
                    )
                    let encoder = JSONEncoder()
                    encoder.dateEncodingStrategy = .iso8601
                    if let data = try? encoder.encode(result) {
                        try? data.write(
                            to: URL(fileURLWithPath: "\(SeashellTemp.dir)/seashell_output_\(bgCommandId).json"),
                            options: .atomic
                        )
                    }
                    DispatchQueue.global(qos: .background).async {
                        _ = DatabaseManager.shared.updateCommand(
                            bgCommandId,
                            stdout: output, stderr: "",
                            exitCode: Int(found ? exitCode : -1),
                            completedAt: Date()
                        )
                    }
                }

                return CallTool.Result(content: [.text("""
                👀 Command running in Wave Terminal (you can see it there)
                📋 Command ID: \(commandId)
                🔧 Command: \(commandString)

                Use get_command_output with command_id "\(commandId)" to retrieve results.
                (Output is ready ~1 s after the command finishes.)
                """)])
            }
            // runCommand failed — fall through to posix_spawn
            logger.warning("wave_run_command failed, falling back to posix_spawn")
        }

        // ── Path B: helper not connected → silent posix_spawn + file capture ──
        let stdoutFile = "\(SeashellTemp.dir)/claude_wave_out_\(commandId).txt"
        let stderrFile = "\(SeashellTemp.dir)/claude_wave_err_\(commandId).txt"
        let doneMarker = "\(SeashellTemp.dir)/claude_wave_done_\(commandId)"
        let shellCmd = "(\(fullCommand)) > \"\(stdoutFile)\" 2> \"\(stderrFile)\"; _rc=$?; echo $_rc > \"\(doneMarker)\"; exit $_rc"

        logger.info("Wave Terminal: spawning via posix_spawn (helper not connected)")

        var pid: pid_t = 0
        let arg0 = strdup("/bin/sh")
        let arg1 = strdup("-c")
        let arg2 = strdup(shellCmd)
        defer { free(arg0); free(arg1); free(arg2) }
        var argv: [UnsafeMutablePointer<CChar>?] = [arg0, arg1, arg2, nil]

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO,  "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&fileActions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&fileActions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        let spawnResult = posix_spawn(&pid, "/bin/sh", &fileActions, nil, &argv, environ)
        if spawnResult != 0 {
            return CallTool.Result(
                content: [.text("❌ Failed to spawn command: \(String(cString: strerror(spawnResult)))")],
                isError: true
            )
        }

        let bgCommandId = commandId
        let bgCommand   = commandString
        let bgStdout    = stdoutFile
        let bgStderr    = stderrFile
        let bgDone      = doneMarker
        DispatchQueue.global(qos: .userInitiated).async {
            var status: Int32 = 0
            waitpid(pid, &status, 0)

            let out = (try? String(contentsOfFile: bgStdout, encoding: .utf8)) ?? ""
            let err = (try? String(contentsOfFile: bgStderr, encoding: .utf8)) ?? ""
            let codeStr = (try? String(contentsOfFile: bgDone, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "-1"
            let code = Int32(codeStr) ?? -1
            unlink(bgStdout); unlink(bgStderr); unlink(bgDone)

            let result = CommandExecutionResult(
                commandId: bgCommandId, command: bgCommand,
                output: out, error: err, exitCode: code, timestamp: Date()
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(result) {
                try? data.write(to: URL(fileURLWithPath: "\(SeashellTemp.dir)/seashell_output_\(bgCommandId).json"), options: .atomic)
            }
            DispatchQueue.global(qos: .background).async {
                _ = DatabaseManager.shared.updateCommand(bgCommandId, stdout: out, stderr: err, exitCode: Int(code), completedAt: Date())
            }
        }

        return CallTool.Result(content: [.text("""
        ⏳ Command running (Wave helper not connected — output captured silently)
        📋 Command ID: \(commandId)
        🔧 Command: \(commandString)

        Use get_command_output with command_id "\(commandId)" to retrieve results.
        (Usually ready within 1-2 seconds for simple commands.)
        """)], isError: false)
    }

    // ── Other terminals: AppleScript keystroke approach ────────────────────

    // Create the output capture script
    let scriptContent = createOutputCaptureScript(command: fullCommand, commandId: commandId)
    let tempScriptFile = "\(SeashellTemp.dir)/claude_script_\(commandId).sh"

    do {
        try scriptContent.write(toFile: tempScriptFile, atomically: true, encoding: .utf8)
        // Make script executable
        try FileManager.default.setAttributes([.posixPermissions: SeashellTemp.scriptPOSIXPermissions], ofItemAtPath: tempScriptFile)
    } catch {
        logger.error("Failed to write script file: \(error)")
        return CallTool.Result(
            content: [.text("Failed to prepare command: \(error.localizedDescription)")],
            isError: true
        )
    }

    // Send to terminal using AppleScript
    let bashCommand = "bash \(tempScriptFile)"
    let appleScript = createAppleScript(for: preferredTerminal, command: bashCommand)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", appleScript]

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    do {
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus == 0 {
            // Command sent successfully
            logger.info("Command sent to \(preferredTerminal.rawValue)")

            // NO BACKGROUND MONITORING - This prevents server crashes

            let result = """
            ✅ Command sent to \(preferredTerminal.rawValue):
            \(commandString)

            📋 Command ID: \(commandId)

            💡 Command executes automatically. After it completes, use 'get_command_output' with ID: \(commandId)
            """

            return CallTool.Result(content: [.text(result)], isError: false)
        } else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let error = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            logger.error("Failed to send command to \(preferredTerminal.rawValue): \(error)")

            // Provide helpful error message
            let installedTerminals = TerminalConfig.detectInstalledTerminals()
            var errorMessage = "Failed to send command to \(preferredTerminal.rawValue): \(error)"

            if !installedTerminals.contains(preferredTerminal) {
                errorMessage += "\n\n⚠️ \(preferredTerminal.rawValue) is not installed."
                if !installedTerminals.isEmpty {
                    errorMessage += "\nAvailable terminals: \(installedTerminals.map { $0.rawValue }.joined(separator: ", "))"
                }
            }

            return CallTool.Result(
                content: [.text(errorMessage)],
                isError: true
            )
        }
    } catch {
        logger.error("Failed to send command: \(error)")
        return CallTool.Result(
            content: [.text("Failed to send command: \(error.localizedDescription)")],
            isError: true
        )
    }
}
