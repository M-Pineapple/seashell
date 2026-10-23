import Foundation
#if !canImport(SQLite3)

/// Stand-in used where SQLite is not available. It does not create files
/// and it does not open a database. Callers get an empty result.
public class DatabaseManager {
    public static let shared = DatabaseManager()

    private init() {}

    public init(path: String) {}

    public func saveCommand(_ command: CommandRecord) -> Bool { false }

    public func updateCommand(
        _ commandId: String,
        stdout: String?,
        stderr: String?,
        exitCode: Int?,
        completedAt: Date
    ) -> Bool { false }

    public func getRecentCommands(limit: Int = 10) -> [CommandRecord] { [] }

    public func searchCommands(query: String, limit: Int = 50) -> [CommandRecord] { [] }

    public func createProject(name: String, path: String?, gitRemote: String? = nil) -> String? { nil }

    public func getProject(byPath path: String) -> Project? { nil }

    public func detectProjectFromDirectory(_ directory: String) -> String? { nil }

    public func getTemplates(category: String? = nil) -> [Template] { [] }

    public func recordAnalyticsEvent(_ eventType: String, data: [String: Any]? = nil) {}

    public func getCommandStatistics(days: Int = 30) -> CommandStatistics {
        CommandStatistics(
            totalCommands: 0,
            successCount: 0,
            failureCount: 0,
            averageDuration: 0,
            topCommands: [],
            topDirectories: [],
            commandsByHour: [],
            commandsByDay: []
        )
    }

    public func cleanupOldCommands(olderThan days: Int) -> Int { 0 }

    public func vacuum() {}
}

#endif
