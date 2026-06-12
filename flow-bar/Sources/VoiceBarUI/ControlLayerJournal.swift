import Foundation
import SQLite3

enum ControlLayerJournal {
    private static let disabledEnvironmentKey = "VOICELAYER_DISABLE_CONTROL_LAYER_JOURNAL"
    private static let topicMarkerDirectory = "markers"
    private static let databaseFileName = "fleet-journal.db"
    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static func append(type: String, payload: [String: String], topic: String = "voice.paste") {
        let environment = ProcessInfo.processInfo.environment
        guard environment[disabledEnvironmentKey] != "1",
              environment["XCTestConfigurationFilePath"] == nil,
              !isRunningUnderXCTest()
        else { return }

        do {
            try appendThrowing(type: type, payload: payload, topic: topic)
        } catch {
            NSLog("[VoiceBar][ControlLayer] journal write failed: %@", String(describing: error))
        }
    }

    private static func isRunningUnderXCTest() -> Bool {
        ProcessInfo.processInfo.processName == "xctest" ||
            Bundle.main.bundlePath.hasSuffix(".xctest")
    }

    private static func appendThrowing(type: String, payload: [String: String], topic: String) throws {
        let fileManager = FileManager.default
        let baseURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/orc", isDirectory: true)
        let markersURL = baseURL.appendingPathComponent(topicMarkerDirectory, isDirectory: true)
        try fileManager.createDirectory(at: markersURL, withIntermediateDirectories: true)

        let dbURL = baseURL.appendingPathComponent(databaseFileName)
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(dbURL.path, &db, flags, nil) == SQLITE_OK, let db else {
            let message = db.map { sqliteErrorMessage($0) } ?? "unable to open database"
            if let db { sqlite3_close(db) }
            throw JournalError.sqlite(message)
        }
        defer { sqlite3_close(db) }

        try exec("PRAGMA busy_timeout=1000;", db: db)
        try exec("PRAGMA journal_mode=WAL;", db: db)
        try exec(
            """
            CREATE TABLE IF NOT EXISTS events (
              seq          INTEGER PRIMARY KEY AUTOINCREMENT,
              ts           TEXT NOT NULL,
              topic        TEXT NOT NULL,
              seat         TEXT,
              type         TEXT NOT NULL,
              payload_json TEXT NOT NULL,
              ack_state    TEXT NOT NULL DEFAULT 'none'
            );
            """,
            db: db
        )

        let payloadJSON = try jsonPayload(payload)
        let timestamp = ISO8601DateFormatter.voiceBarJournalFormatter.string(from: Date())
        let sql = """
        INSERT INTO events (ts, topic, seat, type, payload_json, ack_state)
        VALUES (?, ?, ?, ?, ?, 'none');
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw JournalError.sqlite(sqliteErrorMessage(db))
        }
        defer { sqlite3_finalize(statement) }

        bind(timestamp, to: 1, in: statement)
        bind(topic, to: 2, in: statement)
        sqlite3_bind_null(statement, 3)
        bind(type, to: 4, in: statement)
        bind(payloadJSON, to: 5, in: statement)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw JournalError.sqlite(sqliteErrorMessage(db))
        }

        let seq = sqlite3_last_insert_rowid(db)
        let marker = markersURL.appendingPathComponent(markerTag(for: topic))
        try "\(seq)\n".write(to: marker, atomically: true, encoding: .utf8)
    }

    private static func jsonPayload(_ payload: [String: String]) throws -> String {
        var merged: [String: Any] = [
            "component": "voicebar",
            "pid": ProcessInfo.processInfo.processIdentifier,
        ]
        for (key, value) in payload {
            merged[key] = value
        }
        let data = try JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static func exec(_ sql: String, db: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        defer { sqlite3_free(errorMessage) }
        guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? sqliteErrorMessage(db)
            throw JournalError.sqlite(message)
        }
    }

    private static func bind(_ string: String, to index: Int32, in statement: OpaquePointer) {
        sqlite3_bind_text(statement, index, string, -1, sqliteTransient)
    }

    private static func sqliteErrorMessage(_ db: OpaquePointer) -> String {
        String(cString: sqlite3_errmsg(db))
    }

    static func markerTag(for topic: String) -> String {
        var result = ""
        var inInvalidRun = false
        for scalar in topic.unicodeScalars {
            let isUppercaseASCII = scalar.value >= 65 && scalar.value <= 90
            let isLowercaseASCII = scalar.value >= 97 && scalar.value <= 122
            let isDigit = scalar.value >= 48 && scalar.value <= 57
            let isMarkerPunctuation = scalar == "_" || scalar == "-"
            if isUppercaseASCII || isLowercaseASCII || isDigit || isMarkerPunctuation {
                result.unicodeScalars.append(scalar)
                inInvalidRun = false
            } else if !inInvalidRun {
                result.append("_")
                inInvalidRun = true
            }
        }
        let tag = result.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return tag.isEmpty ? "root" : tag
    }

    private enum JournalError: Error, CustomStringConvertible {
        case sqlite(String)

        var description: String {
            switch self {
            case let .sqlite(message):
                message
            }
        }
    }
}

private extension ISO8601DateFormatter {
    static let voiceBarJournalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
