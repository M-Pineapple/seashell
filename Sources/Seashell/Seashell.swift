import Foundation
import ArgumentParser
import MCP
import Logging
import ServiceLifecycle
import NIOCore

// Command execution result structure
struct CommandExecutionResult: Codable {
    let commandId: String
    let command: String
    let output: String
    let error: String
    let exitCode: Int32
    let timestamp: Date
}

// Actor for thread-safe command results storage
actor CommandResultsStore {
    private var results: [String: CommandExecutionResult] = [:]
    
    func store(_ result: CommandExecutionResult) {
        results[result.commandId] = result
        results["last"] = result
    }
    
    func retrieve(_ commandId: String) -> CommandExecutionResult? {
        return results[commandId]
    }
}

// Global results store
let commandResultsStore = CommandResultsStore()

@main
struct Seashell: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "seashell",
        abstract: "MCP server bridging Claude Desktop and Wave Terminal",
        discussion: """
            Seashell acts as a bridge between Claude Desktop and Wave Terminal,
            enabling Claude to execute commands directly, manage Wave configuration,
            and control terminal blocks via the helper proxy.

            Version 2.2.3: Wave Terminal integration with direct execution!
            """
    )
    
    @Option(name: [.customLong("port"), .customShort("p")], help: "Port for the command receiver (default: 9876)")
    var port: Int = 9876
    
    @Option(name: [.customLong("log-level"), .customShort("l")], help: "Log level: debug, info, warning, error")
    var logLevel: String = "info"
    
    @Flag(name: .long, help: "Enable verbose logging")
    var verbose: Bool = false
    
    @Flag(name: .long, help: "Initialize configuration with example")
    var initConfig: Bool = false
    
    @Flag(name: .long, help: "Validate configuration")
    var validateConfig: Bool = false
    
    mutating func run() async throws {
        // Configure logging
        let logLevelStr = logLevel
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardError(label: label)
            handler.logLevel = Self.parseLogLevel(logLevelStr)
            return handler
        }
        
        let logger = Logger(label: "seashell.server")
        
        // Force database initialization at startup
        logger.info("Initializing database...")
        _ = DatabaseManager.shared
        logger.info("Database initialization complete")
        
        // v4.1.0: Perform temp file cleanup on startup
        performTempCleanup(logger: logger)
        
        // Handle configuration operations
        if initConfig {
            try ConfigurationManager.initializeWithExample(logger: logger)
            print("Configuration initialized at \(ConfigurationManager.configDirectoryPath)")
            return
        }
        
        // Load configuration
        let configManager = ConfigurationManager(logger: logger)
        let config = configManager.current
        
        if validateConfig {
            let errors = configManager.validate()
            if errors.isEmpty {
                print("✅ Configuration is valid")
            } else {
                print("❌ Configuration errors:")
                for error in errors {
                    print("  - \(error)")
                }
            }
            return
        }
        
        // Override with command line arguments if provided
        let actualPort = port != 9876 ? port : config.port
        let _ = logLevel != "info" ? logLevel : config.logging.level
        
        if verbose {
            logger.info("Starting Seashell MCP Server v2.2.3...")
            logger.info("Port: \(actualPort)")
            logger.info("Two-way communication: ENABLED")
            logger.info("Configuration loaded from: \(ConfigurationManager.configDirectoryPath)")
        }
        
        // Auto-connect Wave helper if enabled in config
        if config.wave.helperEnabled {
            logger.info("Wave helper enabled — attempting connection on port \(config.wave.helperPort)")
            await sharedWaveHelperClient.connect()
        }

        // Create the MCP server
        let server = Server(
            name: "Seashell",
            version: "2.2.3",
            capabilities: .init(
                tools: .init(listChanged: false)
            )
        )
        
        // Add missing MCP protocol handlers
        await Self.setupResourceHandlers(server: server, logger: logger)
        await Self.setupPromptHandlers(server: server, logger: logger)
        
        // Add tool handlers
        await server.withMethodHandler(ListTools.self) { _ in
            logger.debug("Listing available tools")
            return ListTools.Result(tools: [
                Tool(
                    name: "suggest_command",
                    description: "Suggests a terminal command based on the user's request",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "query": .object([
                                "type": .string("string"),
                                "description": .string("The user's request or task description")
                            ])
                        ]),
                        "required": .array([.string("query")])
                    ])
                ),
                Tool(
                    name: "execute_command",
                    description: "Executes a terminal command and captures its output. Runs silently by default (no visible block). Pass show_in_wave=true only when you want the user to watch the command run in a visible Wave Terminal block — e.g. a build, install, or multi-step process. For 5 consecutive commands, leave show_in_wave unset so they all run quietly without cluttering Wave.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "command": .object([
                                "type": .string("string"),
                                "description": .string("The command to execute")
                            ]),
                            "working_directory": .object([
                                "type": .string("string"),
                                "description": .string("Optional working directory for command execution")
                            ]),
                            "show_in_wave": .object([
                                "type": .string("boolean"),
                                "description": .string("If true, run in a visible Wave Terminal block so the user can watch. Default false (silent background execution).")
                            ])
                        ]),
                        "required": .array([.string("command")])
                    ])
                ),
                Tool(
                    name: "execute_with_auto_retrieve",
                    description: "Executes a command and automatically waits for and returns its output. Preferred for quick commands that don't need a visible terminal tab. Use open_terminal_tab only for long-running processes like builds or servers.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "command": .object([
                                "type": .string("string"),
                                "description": .string("The command to execute")
                            ]),
                            "working_directory": .object([
                                "type": .string("string"),
                                "description": .string("Optional working directory for command execution")
                            ])
                        ]),
                        "required": .array([.string("command")])
                    ])
                ),
                Tool(
                    name: "preview_command",
                    description: "Preview a command without executing it",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "command": .object([
                                "type": .string("string"),
                                "description": .string("The command to preview")
                            ])
                        ]),
                        "required": .array([.string("command")])
                    ])
                ),
                Tool(
                    name: "get_command_output",
                    description: "Retrieve the output of a previously executed command",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "command_id": .object([
                                "type": .string("string"),
                                "description": .string("The command ID to retrieve output for (use 'last' for most recent)")
                            ])
                        ]),
                        "required": .array([])
                    ])
                ),
                // NEW v4.0 TOOLS
                Tool(
                    name: "execute_pipeline",
                    description: "Execute a pipeline of commands with conditional logic (stop/continue/warn on failure)",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "steps": .object([
                                "type": .string("array"),
                                "description": .string("Array of step objects with 'command', 'on_fail' (stop/continue/warn), optional 'name' and 'working_directory'")
                            ])
                        ]),
                        "required": .array([.string("steps")])
                    ])
                ),
                Tool(
                    name: "execute_with_streaming",
                    description: "Execute a command with real-time output streaming - ideal for long-running builds",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "command": .object([
                                "type": .string("string"),
                                "description": .string("The command to execute")
                            ]),
                            "working_directory": .object([
                                "type": .string("string"),
                                "description": .string("Optional working directory")
                            ]),
                            "update_interval": .object([
                                "type": .string("integer"),
                                "description": .string("Seconds between output updates (default: 2)")
                            ]),
                            "max_duration": .object([
                                "type": .string("integer"),
                                "description": .string("Maximum execution time in seconds (default: 120)")
                            ])
                        ]),
                        "required": .array([.string("command")])
                    ])
                ),
                Tool(
                    name: "save_template",
                    description: "Save a command template with variables for reuse",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "name": .object([
                                "type": .string("string"),
                                "description": .string("Unique name for the template")
                            ]),
                            "template": .object([
                                "type": .string("string"),
                                "description": .string("Command template with {{variable}} placeholders")
                            ]),
                            "description": .object([
                                "type": .string("string"),
                                "description": .string("Optional description of what the template does")
                            ]),
                            "category": .object([
                                "type": .string("string"),
                                "description": .string("Optional category for organization")
                            ])
                        ]),
                        "required": .array([.string("name"), .string("template")])
                    ])
                ),
                Tool(
                    name: "run_template",
                    description: "Execute a saved command template with variable substitution",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "name": .object([
                                "type": .string("string"),
                                "description": .string("Name of the template to run")
                            ]),
                            "variables": .object([
                                "type": .string("object"),
                                "description": .string("Object with variable names and their values")
                            ])
                        ]),
                        "required": .array([.string("name")])
                    ])
                ),
                Tool(
                    name: "list_templates",
                    description: "List all saved command templates",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([:]),
                        "required": .array([])
                    ])
                ),
                // NEW v4.1 TOOLS
                Tool(
                    name: "list_recent_commands",
                    description: "List recent commands from history with status, duration, and exit codes",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "limit": .object([
                                "type": .string("string"),
                                "description": .string("Number of commands to return (1-50, default: 10)")
                            ]),
                            "status": .object([
                                "type": .string("string"),
                                "description": .string("Filter by status: 'all', 'success', 'failed' (default: all)")
                            ]),
                            "search": .object([
                                "type": .string("string"),
                                "description": .string("Search in command text")
                            ])
                        ]),
                        "required": .array([])
                    ])
                ),
                Tool(
                    name: "self_check",
                    description: "Run health check on configuration, database, terminal, and recent error rates",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([:]),
                        "required": .array([])
                    ])
                ),
                // NEW v5.0.0 TOOLS — Clipboard Bridge
                Tool(
                    name: "copy_to_clipboard",
                    description: "Copy text to the macOS system clipboard",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "text": .object([
                                "type": .string("string"),
                                "description": .string("The text to copy to clipboard")
                            ])
                        ]),
                        "required": .array([.string("text")])
                    ])
                ),
                Tool(
                    name: "read_from_clipboard",
                    description: "Read the current contents of the macOS system clipboard",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([:]),
                        "required": .array([])
                    ])
                ),
                // Notification Preferences
                Tool(
                    name: "set_notification_preference",
                    description: "Toggle macOS notification preferences for command completion alerts",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "enabled": .object([
                                "type": .string("boolean"),
                                "description": .string("Enable or disable notifications")
                            ]),
                            "sound": .object([
                                "type": .string("boolean"),
                                "description": .string("Enable or disable notification sounds")
                            ]),
                            "notify_on_success": .object([
                                "type": .string("boolean"),
                                "description": .string("Notify on successful commands")
                            ]),
                            "notify_on_failure": .object([
                                "type": .string("boolean"),
                                "description": .string("Notify on failed commands")
                            ]),
                            "minimum_duration": .object([
                                "type": .string("number"),
                                "description": .string("Minimum command duration (seconds) before notification triggers")
                            ])
                        ]),
                        "required": .array([])
                    ])
                ),
                // Environment Context
                Tool(
                    name: "get_environment_context",
                    description: "Get current terminal environment context including git branch, active venv, node version, docker status, and working directory",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "working_directory": .object([
                                "type": .string("string"),
                                "description": .string("Optional directory to check context for (defaults to current)")
                            ])
                        ]),
                        "required": .array([])
                    ])
                ),
                // Output Intelligence
                Tool(
                    name: "execute_and_parse",
                    description: "Execute a command and return structured parsed output (supports git status, git log, docker ps, test results, ls -la, and JSON)",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "command": .object([
                                "type": .string("string"),
                                "description": .string("The command to execute and parse")
                            ]),
                            "working_directory": .object([
                                "type": .string("string"),
                                "description": .string("Optional working directory")
                            ]),
                            "parser": .object([
                                "type": .string("string"),
                                "description": .string("Force a specific parser: git_status, git_log, docker_ps, test_results, ls, json, auto (default: auto)")
                            ])
                        ]),
                        "required": .array([.string("command")])
                    ])
                ),
                // Environment Snapshots
                Tool(
                    name: "capture_environment",
                    description: "Capture a snapshot of the current shell environment variables with a named label",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "name": .object([
                                "type": .string("string"),
                                "description": .string("Label for this snapshot (e.g. 'before-install', 'clean-state')")
                            ])
                        ]),
                        "required": .array([.string("name")])
                    ])
                ),
                Tool(
                    name: "diff_environment",
                    description: "Compare two environment snapshots and show additions, removals, and changes",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "from": .object([
                                "type": .string("string"),
                                "description": .string("Name of the 'before' snapshot")
                            ]),
                            "to": .object([
                                "type": .string("string"),
                                "description": .string("Name of the 'after' snapshot")
                            ])
                        ]),
                        "required": .array([.string("from"), .string("to")])
                    ])
                ),
                // Workspace Profiles
                Tool(
                    name: "save_workspace_profile",
                    description: "Save current project context as a named workspace profile (directory, commands, env vars, terminal preference)",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "name": .object([
                                "type": .string("string"),
                                "description": .string("Profile name (e.g. 'my-swift-project')")
                            ]),
                            "directory": .object([
                                "type": .string("string"),
                                "description": .string("Working directory for this profile")
                            ]),
                            "default_commands": .object([
                                "type": .string("array"),
                                "description": .string("Array of commonly used commands for this project")
                            ]),
                            "environment_vars": .object([
                                "type": .string("object"),
                                "description": .string("Environment variables to set when loading this profile")
                            ]),
                            "terminal_preference": .object([
                                "type": .string("string"),
                                "description": .string("Preferred terminal for this project (Wave, iTerm, Terminal)")
                            ])
                        ]),
                        "required": .array([.string("name"), .string("directory")])
                    ])
                ),
                Tool(
                    name: "load_workspace_profile",
                    description: "Load a saved workspace profile to restore project context",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "name": .object([
                                "type": .string("string"),
                                "description": .string("Name of the profile to load")
                            ])
                        ]),
                        "required": .array([.string("name")])
                    ])
                ),
                Tool(
                    name: "list_workspace_profiles",
                    description: "List all saved workspace profiles",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([:]),
                        "required": .array([])
                    ])
                ),
                Tool(
                    name: "delete_workspace_profile",
                    description: "Delete a saved workspace profile",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "name": .object([
                                "type": .string("string"),
                                "description": .string("Name of the profile to delete")
                            ])
                        ]),
                        "required": .array([.string("name")])
                    ])
                ),
                // Terminal Sessions
                Tool(
                    name: "open_terminal_tab",
                    description: "Open a new named terminal tab. ONLY use for long-running commands that need their own visible tab (builds, installs, servers, cloning repos). For quick commands, prefer execute_command or execute_with_auto_retrieve instead. If a session already exists, use send_to_session to reuse it.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "name": .object([
                                "type": .string("string"),
                                "description": .string("Name/label for this terminal session")
                            ]),
                            "working_directory": .object([
                                "type": .string("string"),
                                "description": .string("Optional initial working directory")
                            ])
                        ]),
                        "required": .array([.string("name")])
                    ])
                ),
                Tool(
                    name: "send_to_session",
                    description: "Send a command to an existing named terminal session, reusing its tab. Always prefer this over opening a new tab when a relevant session already exists. Use list_sessions first to check for available sessions.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "session_name": .object([
                                "type": .string("string"),
                                "description": .string("Name of the target session")
                            ]),
                            "command": .object([
                                "type": .string("string"),
                                "description": .string("The command to send")
                            ])
                        ]),
                        "required": .array([.string("session_name"), .string("command")])
                    ])
                ),
                Tool(
                    name: "list_sessions",
                    description: "List all active terminal sessions. Check this before opening new tabs to avoid creating duplicates. Reuse existing sessions with send_to_session whenever possible.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([:]),
                        "required": .array([])
                    ])
                ),
                Tool(
                    name: "close_session",
                    description: "Close a named terminal session and optionally close its tab. Use to clean up sessions that are no longer needed. Pass close_tab: true to also close the terminal tab.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "session_name": .object([
                                "type": .string("string"),
                                "description": .string("Name of the session to close")
                            ]),
                            "close_tab": .object([
                                "type": .string("boolean"),
                                "description": .string("If true, also closes the terminal tab (default: false)")
                            ])
                        ]),
                        "required": .array([.string("session_name")])
                    ])
                ),
                Tool(
                    name: "cleanup_sessions",
                    description: "Remove stale terminal sessions that have been inactive. Use periodically to clean up accumulated tabs. Sessions inactive longer than inactive_minutes (default: 30) are removed. Set close_tabs to true to also close the terminal tabs.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "inactive_minutes": .object([
                                "type": .string("number"),
                                "description": .string("Minutes of inactivity before a session is considered stale (default: 30)")
                            ]),
                            "close_tabs": .object([
                                "type": .string("boolean"),
                                "description": .string("If true, also closes the terminal tabs for stale sessions (default: true)")
                            ])
                        ]),
                        "required": .array([])
                    ])
                ),
                // File Watching
                Tool(
                    name: "add_file_watch",
                    description: "Set up a file system watcher that triggers a command when files change",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "path": .object([
                                "type": .string("string"),
                                "description": .string("Directory path to watch")
                            ]),
                            "pattern": .object([
                                "type": .string("string"),
                                "description": .string("Glob pattern to filter (e.g. '*.swift', '*.ts')")
                            ]),
                            "command": .object([
                                "type": .string("string"),
                                "description": .string("Command to run when files change")
                            ]),
                            "debounce_seconds": .object([
                                "type": .string("number"),
                                "description": .string("Debounce interval in seconds (default: 2.0)")
                            ])
                        ]),
                        "required": .array([.string("path"), .string("command")])
                    ])
                ),
                Tool(
                    name: "remove_file_watch",
                    description: "Remove an active file system watcher",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "watcher_id": .object([
                                "type": .string("string"),
                                "description": .string("ID of the watcher to remove")
                            ])
                        ]),
                        "required": .array([.string("watcher_id")])
                    ])
                ),
                Tool(
                    name: "list_file_watches",
                    description: "List all active file system watchers",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([:]),
                        "required": .array([])
                    ])
                ),
                // SSH Execution
                Tool(
                    name: "ssh_execute",
                    description: "Execute a command on a remote host via SSH (key-based authentication only)",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "host": .object([
                                "type": .string("string"),
                                "description": .string("Remote hostname or IP address")
                            ]),
                            "username": .object([
                                "type": .string("string"),
                                "description": .string("SSH username")
                            ]),
                            "command": .object([
                                "type": .string("string"),
                                "description": .string("Command to execute remotely")
                            ]),
                            "identity_file": .object([
                                "type": .string("string"),
                                "description": .string("Path to SSH private key (optional)")
                            ]),
                            "port": .object([
                                "type": .string("integer"),
                                "description": .string("SSH port (default: 22)")
                            ]),
                            "timeout": .object([
                                "type": .string("integer"),
                                "description": .string("Connection timeout in seconds (default: 30)")
                            ]),
                            "profile": .object([
                                "type": .string("string"),
                                "description": .string("Name of saved SSH profile to use instead of specifying host/username/key")
                            ])
                        ]),
                        "required": .array([.string("command")])
                    ])
                ),
                Tool(
                    name: "save_ssh_profile",
                    description: "Save an SSH connection profile for quick reuse",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "name": .object([
                                "type": .string("string"),
                                "description": .string("Profile name")
                            ]),
                            "host": .object([
                                "type": .string("string"),
                                "description": .string("Remote hostname or IP")
                            ]),
                            "username": .object([
                                "type": .string("string"),
                                "description": .string("SSH username")
                            ]),
                            "identity_file": .object([
                                "type": .string("string"),
                                "description": .string("Path to SSH private key")
                            ]),
                            "port": .object([
                                "type": .string("integer"),
                                "description": .string("SSH port (default: 22)")
                            ])
                        ]),
                        "required": .array([.string("name"), .string("host"), .string("username")])
                    ])
                ),
                Tool(
                    name: "list_ssh_profiles",
                    description: "List all saved SSH connection profiles",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([:]),
                        "required": .array([])
                    ])
                ),
                Tool(
                    name: "delete_ssh_profile",
                    description: "Delete a saved SSH connection profile",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "name": .object([
                                "type": .string("string"),
                                "description": .string("Name of the SSH profile to delete")
                            ])
                        ]),
                        "required": .array([.string("name")])
                    ])
                ),
                // Interactive Command Detection
                Tool(
                    name: "check_interactive",
                    description: "Check if a command is interactive (requires TTY/stdin) before executing it. Returns safety level: safe, cautious, interactive, or blocked with suggestions for non-interactive alternatives",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "command": .object([
                                "type": .string("string"),
                                "description": .string("The command to analyse for interactivity")
                            ])
                        ]),
                        "required": .array([.string("command")])
                    ])
                ),

                // ── Wave direct-config tools ──────────────────────────────

                // Read tools (Tier A — safe, no approval needed)
                Tool(
                    name: "wave_get_settings",
                    description: "Read Wave Terminal settings from ~/.waveterm/settings.json. Optionally filter by namespace prefix (e.g. 'ai', 'term', 'window', 'app').",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "namespace": .object([
                                "type": .string("string"),
                                "description": .string("Optional namespace prefix to filter keys (e.g. 'ai', 'term', 'window', 'app')")
                            ])
                        ]),
                        "required": .array([])
                    ])
                ),
                Tool(
                    name: "wave_get_widgets",
                    description: "List all custom widgets configured in Wave Terminal (from ~/.waveterm/widgets.json).",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([:]),
                        "required": .array([])
                    ])
                ),
                Tool(
                    name: "wave_get_ai_presets",
                    description: "List all AI model presets configured in Wave Terminal (from ~/.waveterm/aipresets.json).",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([:]),
                        "required": .array([])
                    ])
                ),
                Tool(
                    name: "wave_get_backgrounds",
                    description: "List all tab background definitions in Wave Terminal (from ~/.waveterm/backgrounds.json).",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([:]),
                        "required": .array([])
                    ])
                ),

                // Write tools (Tier B — require approved=true on second call)
                Tool(
                    name: "wave_set_setting",
                    description: "Update a single Wave Terminal setting in settings.json. First call returns a confirmation; pass approved=true to execute. Examples of keys: 'ai:model', 'term:theme', 'term:fontsize', 'app:tabbar'.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "key": .object([
                                "type": .string("string"),
                                "description": .string("Setting key in Wave's colon-namespaced format (e.g. 'ai:model', 'term:theme')")
                            ]),
                            "value": .object([
                                "description": .string("Value to set (string, number, or boolean)")
                            ]),
                            "approved": .object([
                                "type": .string("boolean"),
                                "description": .string("Set to true to confirm and execute the write")
                            ])
                        ]),
                        "required": .array([.string("key"), .string("value")])
                    ])
                ),
                Tool(
                    name: "wave_create_widget",
                    description: "Create a new custom widget in Wave Terminal (writes to ~/.waveterm/widgets.json). First call returns a confirmation; pass approved=true to execute.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "id": .object([
                                "type": .string("string"),
                                "description": .string("Unique widget identifier (e.g. 'dev-server', 'test-runner')")
                            ]),
                            "label": .object([
                                "type": .string("string"),
                                "description": .string("Display label shown in the widget bar")
                            ]),
                            "view": .object([
                                "type": .string("string"),
                                "description": .string("Block view type: 'term', 'preview', 'web', 'sysinfo', 'launcher'")
                            ]),
                            "icon": .object([
                                "type": .string("string"),
                                "description": .string("Icon name (e.g. 'terminal', 'code', 'robot')")
                            ]),
                            "color": .object([
                                "type": .string("string"),
                                "description": .string("Colour hex code (e.g. '#FF6B6B')")
                            ]),
                            "command": .object([
                                "type": .string("string"),
                                "description": .string("Command to execute when the widget opens (for term blocks)")
                            ]),
                            "cwd": .object([
                                "type": .string("string"),
                                "description": .string("Working directory for the block")
                            ]),
                            "shell_path": .object([
                                "type": .string("string"),
                                "description": .string("Shell binary path (e.g. '/opt/homebrew/bin/fish')")
                            ]),
                            "run_on_start": .object([
                                "type": .string("boolean"),
                                "description": .string("Auto-run command when the widget opens (default: false)")
                            ]),
                            "close_on_exit": .object([
                                "type": .string("boolean"),
                                "description": .string("Close the block when the command exits (default: false)")
                            ]),
                            "env": .object([
                                "type": .string("object"),
                                "description": .string("Environment variables to inject into the block")
                            ]),
                            "approved": .object([
                                "type": .string("boolean"),
                                "description": .string("Set to true to confirm and execute the write")
                            ])
                        ]),
                        "required": .array([.string("id"), .string("label"), .string("view")])
                    ])
                ),
                Tool(
                    name: "wave_update_widget",
                    description: "Update an existing Wave Terminal widget. First call returns a confirmation; pass approved=true to execute.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "id": .object([
                                "type": .string("string"),
                                "description": .string("Widget identifier to update")
                            ]),
                            "label": .object([
                                "type": .string("string"),
                                "description": .string("New display label")
                            ]),
                            "icon": .object([
                                "type": .string("string"),
                                "description": .string("New icon name")
                            ]),
                            "color": .object([
                                "type": .string("string"),
                                "description": .string("New colour hex code")
                            ]),
                            "description": .object([
                                "type": .string("string"),
                                "description": .string("New description")
                            ]),
                            "hidden": .object([
                                "type": .string("boolean"),
                                "description": .string("Hide/show the widget in the widget bar")
                            ]),
                            "view": .object([
                                "type": .string("string"),
                                "description": .string("New block view type")
                            ]),
                            "command": .object([
                                "type": .string("string"),
                                "description": .string("New command")
                            ]),
                            "cwd": .object([
                                "type": .string("string"),
                                "description": .string("New working directory")
                            ]),
                            "approved": .object([
                                "type": .string("boolean"),
                                "description": .string("Set to true to confirm and execute the write")
                            ])
                        ]),
                        "required": .array([.string("id")])
                    ])
                ),
                Tool(
                    name: "wave_delete_widget",
                    description: "Remove a custom widget from Wave Terminal. First call returns a confirmation; pass approved=true to execute.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "id": .object([
                                "type": .string("string"),
                                "description": .string("Widget identifier to delete")
                            ]),
                            "approved": .object([
                                "type": .string("boolean"),
                                "description": .string("Set to true to confirm and execute the deletion")
                            ])
                        ]),
                        "required": .array([.string("id")])
                    ])
                ),
                Tool(
                    name: "wave_set_ai_preset",
                    description: "Create or update a Wave Terminal AI model preset in ~/.waveterm/aipresets.json. First call returns a confirmation; pass approved=true to execute.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "id": .object([
                                "type": .string("string"),
                                "description": .string("Preset identifier (e.g. 'claude-opus', 'gpt-4o')")
                            ]),
                            "name": .object([
                                "type": .string("string"),
                                "description": .string("Display name for the preset (display:name)")
                            ]),
                            "model": .object([
                                "type": .string("string"),
                                "description": .string("Model name (ai:model, e.g. 'claude-opus-4-5-20251001')")
                            ]),
                            "api_type": .object([
                                "type": .string("string"),
                                "description": .string("API provider type (ai:apitype, e.g. 'anthropic', 'openai')")
                            ]),
                            "base_url": .object([
                                "type": .string("string"),
                                "description": .string("API base URL (ai:baseurl)")
                            ]),
                            "api_token": .object([
                                "type": .string("string"),
                                "description": .string("API token (ai:apitoken) — use with care")
                            ]),
                            "ai_name": .object([
                                "type": .string("string"),
                                "description": .string("Display name for the AI (ai:name)")
                            ]),
                            "max_tokens": .object([
                                "type": .string("number"),
                                "description": .string("Maximum token count (ai:maxtokens)")
                            ]),
                            "timeout_ms": .object([
                                "type": .string("number"),
                                "description": .string("Request timeout in milliseconds (ai:timeoutms)")
                            ]),
                            "display_order": .object([
                                "type": .string("number"),
                                "description": .string("Sort order in the preset dropdown (display:order)")
                            ]),
                            "approved": .object([
                                "type": .string("boolean"),
                                "description": .string("Set to true to confirm and execute the write")
                            ])
                        ]),
                        "required": .array([.string("id")])
                    ])
                ),
                Tool(
                    name: "wave_set_theme",
                    description: "Set the Wave Terminal theme (writes 'term:theme' to settings.json). First call returns a confirmation; pass approved=true to execute.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "theme": .object([
                                "type": .string("string"),
                                "description": .string("Theme name (e.g. 'nord', 'dracula', 'solarized-dark', 'github-dark')")
                            ]),
                            "approved": .object([
                                "type": .string("boolean"),
                                "description": .string("Set to true to confirm and execute the write")
                            ])
                        ]),
                        "required": .array([.string("theme")])
                    ])
                ),
                Tool(
                    name: "wave_set_appearance",
                    description: "Update Wave Terminal window or terminal appearance settings (writes to settings.json). First call returns a confirmation; pass approved=true to execute. Supported: font_size, font_family, transparency, tab_bar, ctrl_v_paste, confirm_quit, mac_option_is_meta, bell_sound, bell_indicator, default_new_block.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "font_size": .object([
                                "type": .string("number"),
                                "description": .string("Terminal font size in points (term:fontsize)")
                            ]),
                            "font_family": .object([
                                "type": .string("string"),
                                "description": .string("Terminal font family name (term:fontfamily)")
                            ]),
                            "transparency": .object([
                                "type": .string("number"),
                                "description": .string("Terminal background transparency 0.0–1.0 (term:transparency)")
                            ]),
                            "tab_bar": .object([
                                "type": .string("string"),
                                "description": .string("Tab bar position: 'top' or 'left' (app:tabbar)")
                            ]),
                            "ctrl_v_paste": .object([
                                "type": .string("boolean"),
                                "description": .string("Enable Ctrl+V paste (app:ctrlvpaste)")
                            ]),
                            "confirm_quit": .object([
                                "type": .string("boolean"),
                                "description": .string("Show quit confirmation dialog (app:confirmquit)")
                            ]),
                            "mac_option_is_meta": .object([
                                "type": .string("boolean"),
                                "description": .string("Treat Option key as Meta in terminal (term:macoptionismeta)")
                            ]),
                            "bell_sound": .object([
                                "type": .string("boolean"),
                                "description": .string("Enable terminal bell sound (term:bellsound)")
                            ]),
                            "bell_indicator": .object([
                                "type": .string("boolean"),
                                "description": .string("Show bell indicator in tab (term:bellindicator)")
                            ]),
                            "default_new_block": .object([
                                "type": .string("string"),
                                "description": .string("Default block type for new blocks (app:defaultnewblock)")
                            ]),
                            "approved": .object([
                                "type": .string("boolean"),
                                "description": .string("Set to true to confirm and execute the write")
                            ])
                        ]),
                        "required": .array([])
                    ])
                ),

                // ── Wave helper-block tools — require helper block ────────

                Tool(
                    name: "wave_helper_status",
                    description: "Check whether the Seashell Helper block is connected. Shows which tool tier is available.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([:]),
                        "required": .array([])
                    ])
                ),
                Tool(
                    name: "wave_connect_helper",
                    description: "Connect the MCP server to the Seashell Helper block running inside Wave Terminal. The helper must already be running (open the Seashell Helper widget in Wave first).",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([:]),
                        "required": .array([])
                    ])
                ),
                Tool(
                    name: "wave_list_workspaces",
                    description: "List all Wave Terminal workspaces with their IDs, names, icons, and colours. Requires the Seashell Helper block to be running.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([:]),
                        "required": .array([])
                    ])
                ),
                Tool(
                    name: "wave_list_blocks",
                    description: "List blocks in Wave Terminal, optionally filtered by workspace, tab, or view type. Requires the Seashell Helper block.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "workspace_id": .object([
                                "type": .string("string"),
                                "description": .string("Filter by workspace ID")
                            ]),
                            "tab_id": .object([
                                "type": .string("string"),
                                "description": .string("Filter by tab ID")
                            ]),
                            "view": .object([
                                "type": .string("string"),
                                "description": .string("Filter by view type: term, preview, web, sysinfo")
                            ])
                        ]),
                        "required": .array([])
                    ])
                ),
                Tool(
                    name: "wave_create_block",
                    description: "Create a new block in Wave Terminal. First call returns a confirmation; pass approved=true to execute. Requires the Seashell Helper block.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "tab_id": .object([
                                "type": .string("string"),
                                "description": .string("Tab ID where the block will be created")
                            ]),
                            "view": .object([
                                "type": .string("string"),
                                "description": .string("Block type: term, preview, web, sysinfo, launcher")
                            ]),
                            "command": .object([
                                "type": .string("string"),
                                "description": .string("Command to run (for term blocks)")
                            ]),
                            "cwd": .object([
                                "type": .string("string"),
                                "description": .string("Working directory")
                            ]),
                            "run_on_start": .object([
                                "type": .string("boolean"),
                                "description": .string("Auto-run command when block opens")
                            ]),
                            "close_on_exit": .object([
                                "type": .string("boolean"),
                                "description": .string("Close block when command exits")
                            ]),
                            "url": .object([
                                "type": .string("string"),
                                "description": .string("URL to open (for web blocks)")
                            ]),
                            "file": .object([
                                "type": .string("string"),
                                "description": .string("File path to open (for preview blocks)")
                            ]),
                            "approved": .object([
                                "type": .string("boolean"),
                                "description": .string("Set to true to confirm and execute")
                            ])
                        ]),
                        "required": .array([.string("tab_id"), .string("view")])
                    ])
                ),
                Tool(
                    name: "wave_delete_block",
                    description: "Delete a block from Wave Terminal. First call returns a confirmation; pass approved=true to execute. Requires the Seashell Helper block.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "block_id": .object([
                                "type": .string("string"),
                                "description": .string("Block ID to delete")
                            ]),
                            "approved": .object([
                                "type": .string("boolean"),
                                "description": .string("Set to true to confirm and execute")
                            ])
                        ]),
                        "required": .array([.string("block_id")])
                    ])
                ),
                Tool(
                    name: "wave_get_scrollback",
                    description: "Get terminal scrollback content from a Wave block. Requires the Seashell Helper block.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "block_id": .object([
                                "type": .string("string"),
                                "description": .string("Block ID to get scrollback from")
                            ]),
                            "last_command_only": .object([
                                "type": .string("boolean"),
                                "description": .string("Return only the output of the last command (default: false)")
                            ])
                        ]),
                        "required": .array([.string("block_id")])
                    ])
                ),
                Tool(
                    name: "wave_run_in_block",
                    description: "Run a command in a new Wave Terminal block. First call returns a confirmation; pass approved=true to execute. Requires the Seashell Helper block.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "tab_id": .object([
                                "type": .string("string"),
                                "description": .string("Tab ID where the new block will be created")
                            ]),
                            "command": .object([
                                "type": .string("string"),
                                "description": .string("Command to execute in the new block")
                            ]),
                            "cwd": .object([
                                "type": .string("string"),
                                "description": .string("Working directory for the command")
                            ]),
                            "env": .object([
                                "type": .string("object"),
                                "description": .string("Environment variables to inject")
                            ]),
                            "close_on_exit": .object([
                                "type": .string("boolean"),
                                "description": .string("Close the block when the command exits (default: false)")
                            ]),
                            "approved": .object([
                                "type": .string("boolean"),
                                "description": .string("Set to true to confirm and execute")
                            ])
                        ]),
                        "required": .array([.string("tab_id"), .string("command")])
                    ])
                ),
                Tool(
                    name: "wave_view_file",
                    description: "Open a file in a Wave Terminal preview block. Requires the Seashell Helper block.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "tab_id": .object([
                                "type": .string("string"),
                                "description": .string("Tab ID where the preview block will open")
                            ]),
                            "file": .object([
                                "type": .string("string"),
                                "description": .string("Absolute path to the file to preview")
                            ])
                        ]),
                        "required": .array([.string("tab_id"), .string("file")])
                    ])
                ),
                Tool(
                    name: "wave_edit_file",
                    description: "Open a file for editing in Wave Terminal. First call returns a confirmation; pass approved=true to execute. Requires the Seashell Helper block.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "tab_id": .object([
                                "type": .string("string"),
                                "description": .string("Tab ID where the editor block will open")
                            ]),
                            "file": .object([
                                "type": .string("string"),
                                "description": .string("Absolute path to the file to edit")
                            ]),
                            "approved": .object([
                                "type": .string("boolean"),
                                "description": .string("Set to true to confirm and execute")
                            ])
                        ]),
                        "required": .array([.string("tab_id"), .string("file")])
                    ])
                ),

                // ── Secrets ─────────────────────────────────────────────────────────
                Tool(
                    name: "wave_secret_list",
                    description: "List all Wave Terminal secret keys (Tier C — requires approved=true and a non-empty reason). Requires the Seashell Helper.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "approved": .object(["type": .string("boolean"), "description": .string("Set to true after reviewing the action")]),
                            "reason":   .object(["type": .string("string"),  "description": .string("Why you need to access secrets")])
                        ]),
                        "required": .array([.string("approved"), .string("reason")])
                    ])
                ),
                Tool(
                    name: "wave_secret_set",
                    description: "Set a Wave Terminal secret (Tier C — requires approved=true and a non-empty reason). Requires the Seashell Helper.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "key":      .object(["type": .string("string"),  "description": .string("Secret key name")]),
                            "value":    .object(["type": .string("string"),  "description": .string("Secret value to store")]),
                            "approved": .object(["type": .string("boolean"), "description": .string("Set to true to confirm")]),
                            "reason":   .object(["type": .string("string"),  "description": .string("Why you are setting this secret")])
                        ]),
                        "required": .array([.string("key"), .string("value"), .string("approved"), .string("reason")])
                    ])
                ),
                Tool(
                    name: "wave_secret_get",
                    description: "Read a Wave Terminal secret (Tier C — requires approved=true and a non-empty reason). The plaintext value is withheld unless SEASHELL_ALLOW_SECRET_READ=1. Requires the Seashell Helper.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "key":      .object(["type": .string("string"),  "description": .string("Secret key name")]),
                            "approved": .object(["type": .string("boolean"), "description": .string("Set to true to confirm")]),
                            "reason":   .object(["type": .string("string"),  "description": .string("Why you need this secret")])
                        ]),
                        "required": .array([.string("key"), .string("approved"), .string("reason")])
                    ])
                ),
                Tool(
                    name: "wave_secret_delete",
                    description: "Delete a Wave Terminal secret (Tier C — requires approved=true and a non-empty reason). Requires the Seashell Helper.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "key":      .object(["type": .string("string"),  "description": .string("Secret key name to delete")]),
                            "approved": .object(["type": .string("boolean"), "description": .string("Set to true to confirm")]),
                            "reason":   .object(["type": .string("string"),  "description": .string("Why you are deleting this secret")])
                        ]),
                        "required": .array([.string("key"), .string("approved"), .string("reason")])
                    ])
                ),

                // ── Convenience tools ───────────────────────────────────────────────
                Tool(
                    name: "wave_create_fish_widget",
                    description: "Add a Fish shell widget to the Wave widget bar (convenience wrapper around wave_create_widget). First call returns a confirmation; pass approved=true to execute.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "id":       .object(["type": .string("string"),  "description": .string("Widget ID (default: fish-shell)")]),
                            "label":    .object(["type": .string("string"),  "description": .string("Display label (default: Fish)")]),
                            "icon":     .object(["type": .string("string"),  "description": .string("Icon name (default: terminal)")]),
                            "cwd":      .object(["type": .string("string"),  "description": .string("Working directory for the fish shell")]),
                            "approved": .object(["type": .string("boolean"), "description": .string("Set to true to confirm")])
                        ]),
                        "required": .array([])
                    ])
                ),
                Tool(
                    name: "wave_bootstrap_workspace",
                    description: "Bootstrap a Wave tab with a project-specific block layout. Templates: general, python-dev, node-dev, swift-dev. First call returns a confirmation; pass approved=true to execute. Requires the Seashell Helper.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "tab_id":   .object(["type": .string("string"),  "description": .string("Tab ID to bootstrap blocks into")]),
                            "template": .object(["type": .string("string"),  "description": .string("Template name: general, python-dev, node-dev, swift-dev (default: general)")]),
                            "cwd":      .object(["type": .string("string"),  "description": .string("Working directory for terminal blocks")]),
                            "approved": .object(["type": .string("boolean"), "description": .string("Set to true to confirm and execute")])
                        ]),
                        "required": .array([.string("tab_id")])
                    ])
                ),
                // ── Inbox tools — let the user leave Claude notes from Wave Terminal ──
                Tool(
                    name: "read_user_inbox",
                    description: "Drain unread notes the user left for Claude via the `seashell-msg` shell command. Aggregates across the global inbox (~/.seashell/inbox.jsonl) AND every registered project inbox (.seashell-inbox/inbox.jsonl in each project root). Each note carries a timestamp, working directory, project label, and (optionally) attachments + a reply_token. Read messages are archived. Call this when the user's chat message is brief or implies they were elsewhere (e.g. \"?\", \"continue\", \"check inbox\"). If any returned message has a reply_token, you should answer via reply_to_user.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([:]),
                        "required": .array([])
                    ])
                ),
                Tool(
                    name: "inbox_count",
                    description: "Cheap peek across the global inbox + every registered project inbox. Returns total unread count, age of the oldest message, and a per-project breakdown. Call before `read_user_inbox` if you only want to know whether anything is waiting.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([:]),
                        "required": .array([])
                    ])
                ),
                Tool(
                    name: "inbox_history",
                    description: "Browse archived messages across all inboxes (global + every registered project). Sorted most-recent-first.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "limit":   .object(["type": .string("string"), "description": .string("Number of recent messages to return (1-100, default: 20)")]),
                            "search":  .object(["type": .string("string"), "description": .string("Optional substring filter on message text (case-insensitive)")]),
                            "project": .object(["type": .string("string"), "description": .string("Optional project label to filter by (matches the basename of project paths in ~/.seashell/projects.jsonl)")])
                        ]),
                        "required": .array([])
                    ])
                ),
                Tool(
                    name: "reply_to_user",
                    description: "Post a reply to a user inbox message. Use this when a message returned by `read_user_inbox` had a `reply_token` — that means the user invoked `seashell-ask` and is blocking on your answer. The reply is written to the appropriate `replies.jsonl` (global or per-project) and `seashell-ask` picks it up within ~1 second. If the user just left a note via `seashell-msg` (no reply_token), no reply call is needed — answer in chat normally.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "message_id":   .object(["type": .string("string"), "description": .string("The id field from the original inbox record (required)")]),
                            "text":         .object(["type": .string("string"), "description": .string("Your reply text — what the user will see in their terminal (required)")]),
                            "project_path": .object(["type": .string("string"), "description": .string("Optional absolute project path to scope the reply to. If omitted, Seashell auto-detects from the message id by searching archives.")])
                        ]),
                        "required": .array([.string("message_id"), .string("text")])
                    ])
                ),
                Tool(
                    name: "read_my_replies",
                    description: "Browse the OUTBOUND history — replies you've previously sent via `reply_to_user`. Aggregates across the global inbox and every registered project's `replies.jsonl`. Use this to answer questions like \"what was the last thing you said in this project?\" or \"what did you tell me about X?\" without needing to manually open the file. Sorted most-recent-first.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "limit":   .object(["type": .string("string"), "description": .string("Number of recent replies to return (1-100, default: 10)")]),
                            "search":  .object(["type": .string("string"), "description": .string("Optional substring filter on reply text (case-insensitive)")]),
                            "project": .object(["type": .string("string"), "description": .string("Optional project label to filter by (matches the basename of project paths in ~/.seashell/projects.jsonl). Use 'global' to filter to the global inbox.")])
                        ]),
                        "required": .array([])
                    ])
                ),
                Tool(
                    name: "read_session_transcript",
                    description: "Read the most recent N turns of a Claude Code session's transcript, without resuming it. Use this when the user asks 'what's the status of project X?' or 'what did we last talk about in <project>?' — you read the actual transcript instead of relying on memory. Resolution: pass `project` (fuzzy name) and Seashell follows the project's `.seashell-inbox/primary-session.txt` pointer (or falls back to the largest .jsonl in that project's Claude Code dir). Or pass `session_id` (full UUID or prefix) for direct lookup. Returns formatted user/assistant turns; tool calls are flagged with `[used: <tool>]` and thinking blocks with `[thought]`. Long messages auto-truncate.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "project":        .object(["type": .string("string"), "description": .string("Project name to look up (fuzzy-matched against the basename of every Claude Code project dir). Resolved to the project's primary session.")]),
                            "session_id":     .object(["type": .string("string"), "description": .string("Full session UUID or unique prefix. Takes precedence over `project` if both given.")]),
                            "last_n":         .object(["type": .string("string"), "description": .string("How many recent user/assistant turns to return (1-200, default: 30). Tool-result-only turns and unrelated metadata lines are skipped automatically.")]),
                            "max_body_chars": .object(["type": .string("string"), "description": .string("Per-message body truncation (80-5000, default: 800). Long messages get a '… (truncated, N more chars)' suffix.")])
                        ]),
                        "required": .array([])
                    ])
                )
            ])
        }

        await server.withMethodHandler(CallTool.self) { params in
            logger.info("Tool called: \(params.name)")
            
            switch params.name {
            case "suggest_command":
                return try await handleSuggestCommand(params: params, logger: logger)
            case "execute_command":
                // Use V2 without background monitoring to prevent crashes
                return try await handleExecuteCommandV2NoMonitoring(params: params, logger: logger, config: config)
            case "execute_with_auto_retrieve":
                // Use enhanced auto-retrieve with progressive delays
                return try await handleExecuteWithAutoRetrieveEnhanced(params: params, logger: logger, config: config)
            case "preview_command":
                return await handlePreviewCommand(params: params, logger: logger)
            case "get_command_output":
                return await handleGetCommandOutput(params: params, logger: logger)
            // NEW v4.0 TOOL HANDLERS
            case "execute_pipeline":
                return try await handleExecutePipeline(params: params, logger: logger, config: config)
            case "execute_with_streaming":
                return try await handleExecuteWithStreaming(params: params, logger: logger, config: config)
            case "save_template":
                return await handleSaveTemplate(params: params, logger: logger)
            case "run_template":
                return try await handleRunTemplate(params: params, logger: logger, config: config)
            case "list_templates":
                return await handleListTemplates(params: params, logger: logger)
            // NEW v4.1 TOOL HANDLERS
            case "list_recent_commands":
                return await handleListRecentCommands(params: params, logger: logger)
            case "self_check":
                return await handleSelfCheck(params: params, logger: logger)
            // NEW v5.0.0 TOOL HANDLERS — Clipboard
            case "copy_to_clipboard":
                return await handleCopyToClipboard(params: params, logger: logger)
            case "read_from_clipboard":
                return await handleReadFromClipboard(params: params, logger: logger)
            // Notifications
            case "set_notification_preference":
                return await handleSetNotificationPreference(params: params, logger: logger)
            // Environment Context
            case "get_environment_context":
                return await handleGetEnvironmentContext(params: params, logger: logger, config: config)
            // Output Intelligence
            case "execute_and_parse":
                return try await handleExecuteAndParse(params: params, logger: logger, config: config)
            // Environment Snapshots
            case "capture_environment":
                return await handleCaptureEnvironment(params: params, logger: logger)
            case "diff_environment":
                return await handleDiffEnvironment(params: params, logger: logger)
            // Workspace Profiles
            case "save_workspace_profile":
                return await handleSaveWorkspaceProfile(params: params, logger: logger)
            case "load_workspace_profile":
                return await handleLoadWorkspaceProfile(params: params, logger: logger)
            case "list_workspace_profiles":
                return await handleListWorkspaceProfiles(params: params, logger: logger)
            case "delete_workspace_profile":
                return await handleDeleteWorkspaceProfile(params: params, logger: logger)
            // Terminal Sessions
            case "open_terminal_tab":
                return await handleOpenTerminalTab(params: params, logger: logger)
            case "send_to_session":
                return await handleSendToSession(params: params, logger: logger)
            case "list_sessions":
                return await handleListSessions(params: params, logger: logger)
            case "close_session":
                return await handleCloseSession(params: params, logger: logger)
            case "cleanup_sessions":
                return await handleCleanupSessions(params: params, logger: logger)
            // File Watching
            case "add_file_watch":
                return await handleAddFileWatch(params: params, logger: logger)
            case "remove_file_watch":
                return await handleRemoveFileWatch(params: params, logger: logger)
            case "list_file_watches":
                return await handleListFileWatches(params: params, logger: logger)
            // Interactive Command Detection
            case "check_interactive":
                return await handleCheckInteractive(params: params, logger: logger)
            // SSH Execution
            case "ssh_execute":
                return await handleSSHExecute(params: params, logger: logger, config: config)
            case "save_ssh_profile":
                return await handleSaveSSHProfile(params: params, logger: logger)
            case "list_ssh_profiles":
                return await handleListSSHProfiles(params: params, logger: logger)
            case "delete_ssh_profile":
                return await handleDeleteSSHProfile(params: params, logger: logger)

            // ── Wave helper-block tools — helper block required ──────
            case "wave_helper_status":
                return await handleWaveHelperStatus(params: params, logger: logger, config: config)
            case "wave_connect_helper":
                return await handleWaveConnectHelper(params: params, logger: logger, config: config)
            case "wave_list_workspaces":
                return await handleWaveListWorkspaces(params: params, logger: logger, config: config)
            case "wave_list_blocks":
                return await handleWaveListBlocks(params: params, logger: logger, config: config)
            case "wave_create_block":
                return await handleWaveCreateBlock(params: params, logger: logger, config: config)
            case "wave_delete_block":
                return await handleWaveDeleteBlock(params: params, logger: logger, config: config)
            case "wave_get_scrollback":
                return await handleWaveGetScrollback(params: params, logger: logger, config: config)
            case "wave_run_in_block":
                return await handleWaveRunInBlock(params: params, logger: logger, config: config)
            case "wave_view_file":
                return await handleWaveViewFile(params: params, logger: logger, config: config)
            case "wave_edit_file":
                return await handleWaveEditFile(params: params, logger: logger, config: config)

            // ── Wave direct-config tools ──────────────────────────
            // Read tools (Tier A)
            case "wave_get_settings":
                return await handleWaveGetSettings(params: params, logger: logger, config: config)
            case "wave_get_widgets":
                return await handleWaveGetWidgets(params: params, logger: logger, config: config)
            case "wave_get_ai_presets":
                return await handleWaveGetAIPresets(params: params, logger: logger, config: config)
            case "wave_get_backgrounds":
                return await handleWaveGetBackgrounds(params: params, logger: logger, config: config)
            // Write tools (Tier B — confirm on first call, execute on second)
            case "wave_set_setting":
                return await handleWaveSetSetting(params: params, logger: logger, config: config)
            case "wave_create_widget":
                return await handleWaveCreateWidget(params: params, logger: logger, config: config)
            case "wave_update_widget":
                return await handleWaveUpdateWidget(params: params, logger: logger, config: config)
            case "wave_delete_widget":
                return await handleWaveDeleteWidget(params: params, logger: logger, config: config)
            case "wave_set_ai_preset":
                return await handleWaveSetAIPreset(params: params, logger: logger, config: config)
            case "wave_set_theme":
                return await handleWaveSetTheme(params: params, logger: logger, config: config)
            case "wave_set_appearance":
                return await handleWaveSetAppearance(params: params, logger: logger, config: config)

            // ── Wave secret/workspace tools ──────────────────────────
            case "wave_secret_list":
                return await handleWaveSecretList(params: params, logger: logger, config: config)
            case "wave_secret_set":
                return await handleWaveSecretSet(params: params, logger: logger, config: config)
            case "wave_secret_get":
                return await handleWaveSecretGet(params: params, logger: logger, config: config)
            case "wave_secret_delete":
                return await handleWaveSecretDelete(params: params, logger: logger, config: config)
            case "wave_create_fish_widget":
                return await handleWaveCreateFishWidget(params: params, logger: logger, config: config)
            case "wave_bootstrap_workspace":
                return await handleWaveBootstrapWorkspace(params: params, logger: logger, config: config)

            // ── Inbox tools ──────────────────────────────────────────
            case "read_user_inbox":
                return await handleReadUserInbox(params: params, logger: logger)
            case "inbox_count":
                return await handleInboxCount(params: params, logger: logger)
            case "inbox_history":
                return await handleInboxHistory(params: params, logger: logger)
            case "reply_to_user":
                return await handleReplyToUser(params: params, logger: logger)
            case "read_my_replies":
                return await handleReadMyReplies(params: params, logger: logger)
            case "read_session_transcript":
                return await handleReadSessionTranscript(params: params, logger: logger)

            default:
                return CallTool.Result(
                    content: [.text("Unknown tool: \(params.name)")],
                    isError: true
                )
            }
        }
        
        // Create transport and start server
        let transport = StdioTransport(logger: logger)
        let mcpService = MCPService(server: server, transport: transport)

        // Create command receiver service
        let commandReceiver = CommandReceiverService(port: actualPort, server: server, logger: logger)

        // Background task: auto-connect to the Wave helper whenever it becomes available.
        // Tries every 8 seconds so the first tool call always finds a live connection.
        Task.detached(priority: .background) {
            while !Task.isCancelled {
                let connected = await sharedWaveHelperClient.isConnected()
                if !connected {
                    await sharedWaveHelperClient.connect()
                }
                try? await Task.sleep(nanoseconds: 8_000_000_000)
            }
        }

        // Create service group
        let serviceGroup = ServiceGroup(
            services: [mcpService, commandReceiver],
            gracefulShutdownSignals: [.sigterm, .sigint],
            logger: logger
        )
        
        logger.info("MCP Server started successfully")
        logger.info("Command receiver listening on port \(actualPort)")
        
        // Add error handling for port conflicts
        do {
            // Run the service group
            try await serviceGroup.run()
        } catch {
            logger.error("Service group error: \(error)")
            
            // Check if it's a port binding error
            if let error = error as? NIOCore.IOError, error.errnoCode == EADDRINUSE {
                logger.error("Port \(actualPort) is already in use. Please stop any existing instances or use a different port.")
                print("\n❌ Error: Port \(actualPort) is already in use.")
                print("Try: lsof -i :\(actualPort) to find the process using this port")
                Foundation.exit(1)
            }
            
            throw error
        }
    }
    
    private static func parseLogLevel(_ level: String) -> Logger.Level {
        switch level.lowercased() {
        case "debug": return .debug
        case "info": return .info
        case "warning": return .warning
        case "error": return .error
        default: return .info
        }
    }
}

// Import the enhanced suggest command handler
// The basic implementation is replaced by CommandSuggestionEngine.swift

func handlePreviewCommand(params: CallTool.Parameters, logger: Logger) async -> CallTool.Result {
    guard let arguments = params.arguments,
          let command = arguments["command"],
          case .string(let commandString) = command else {
        return CallTool.Result(
            content: [.text("Missing or invalid 'command' parameter")],
            isError: true
        )
    }
    
    logger.debug("Previewing command: \(commandString)")
    
    let preview = """
    Command Preview:
    ================
    \(commandString)
    
    This command will be executed in your current shell environment.
    Use 'execute_command' to run it.
    """
    
    return CallTool.Result(content: [.text(preview)], isError: false)
}

// New tool handler to retrieve command output
func handleGetCommandOutput(params: CallTool.Parameters, logger: Logger) async -> CallTool.Result {
    var commandId = "last" // Default to last command
    
    if let arguments = params.arguments,
       let id = arguments["command_id"],
       case .string(let idString) = id {
        commandId = idString
    }
    
    logger.info("Retrieving output for command ID: \(commandId)")
    
    // First try to get from memory
    var result = await commandResultsStore.retrieve(commandId)
    
    // If not in memory and not "last", try to read from disk
    if result == nil && commandId != "last" {
        logger.info("Not found in memory, checking disk...")
        let outputFile = "/tmp/seashell_output_\(commandId).json"
        
        if FileManager.default.fileExists(atPath: outputFile) {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: outputFile))
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                
                result = try decoder.decode(CommandExecutionResult.self, from: data)
                logger.info("Found and decoded output from disk")
                
                // Store it for future use
                if let result = result {
                    await commandResultsStore.store(result)
                }
            } catch {
                logger.error("Failed to read/decode output file: \(error)")
            }
        }
    }
    
    if let result = result {
        var output = """
        📊 Command Output Retrieved:
        ========================
        Command: \(result.command)
        Exit Code: \(result.exitCode)
        Timestamp: \(result.timestamp)
        
        Output:
        \(result.output)
        """
        
        if !result.error.isEmpty && result.error != "\n" {
            output += "\n\nError Output:\n\(result.error)"
        }
        
        return CallTool.Result(content: [.text(output)], isError: false)
    } else {
        // List available output files for debugging
        let tempDir = "/tmp"
        let files = try? FileManager.default.contentsOfDirectory(atPath: tempDir)
            .filter { $0.starts(with: "seashell_output_") && $0.hasSuffix(".json") }
            .sorted()
            .suffix(5)
        
        var message = "No output found for command ID: \(commandId). The command may still be running or hasn't been executed yet."
        if let files = files, !files.isEmpty {
            message += "\n\nRecent output files available:\n" + files.joined(separator: "\n")
        }
        
        return CallTool.Result(content: [.text(message)], isError: false)
    }
}

// createOutputCaptureScript and createAppleScript are now in TerminalUtilities.swift

// Function to wait for and retrieve command output
func waitForCommandOutput(commandId: String, timeout: TimeInterval = 30, logger: Logger) async throws -> CommandExecutionResult? {
    let outputFile = "/tmp/seashell_output_\(commandId).json"
    let markerFile = "\(outputFile).complete"
    
    let startTime = Date()
    
    // Poll for completion
    while Date().timeIntervalSince(startTime) < timeout {
        if FileManager.default.fileExists(atPath: markerFile) {
            // Small delay to ensure file is fully written
            try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
            
            // Read the output file
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: outputFile))
                
                // Configure decoder with proper date format
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                
                let result = try decoder.decode(CommandExecutionResult.self, from: data)
                
                logger.info("Successfully decoded command output for \(commandId)")
                
                // Clean up files
                try? FileManager.default.removeItem(atPath: outputFile)
                try? FileManager.default.removeItem(atPath: markerFile)
                
                return result
            } catch {
                logger.error("Failed to decode command output: \(error)")
                // Try to read the raw content for debugging
                if let rawContent = try? String(contentsOf: URL(fileURLWithPath: outputFile)) {
                    logger.error("Raw JSON content: \(rawContent)")
                }
                // Don't remove files on error so we can debug
                return nil
            }
        }
        
        // Wait a bit before checking again
        try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
    }
    
    logger.info("Timeout reached waiting for command output")
    return nil
}
