import Foundation
import SQLite3
import MideaKit

/// Appends energy/power samples to a small SQLite database so usage can be charted later.
final class EnergyLog: @unchecked Sendable {
    static let shared = EnergyLog()

    struct Summary: Equatable {
        var nowWatts: Double?
        var todayKWh: Double?
        var weekKWh: Double?
        var totalKWh: Double?
        var sampleCount: Int = 0
    }

    private let queue = DispatchQueue(label: "breeze.energy")
    private var db: OpaquePointer?
    let fileURL: URL

    private init() {
        fileURL = CredentialStore.directory.appendingPathComponent("energy.sqlite")
        queue.sync { open() }
    }

    private func open() {
        try? FileManager.default.createDirectory(at: CredentialStore.directory, withIntermediateDirectories: true)
        guard sqlite3_open(fileURL.path, &db) == SQLITE_OK else { db = nil; return }
        exec("""
        CREATE TABLE IF NOT EXISTS samples (
            ts INTEGER NOT NULL, device_id INTEGER NOT NULL,
            power_w REAL, total_kwh REAL, run_kwh REAL,
            indoor_c REAL, target_c REAL, is_on INTEGER, mode INTEGER);
        CREATE INDEX IF NOT EXISTS samples_device_ts ON samples(device_id, ts);
        """)
    }

    private func exec(_ sql: String) {
        guard let db else { return }
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    func record(deviceId: UInt64, state: ACState) {
        guard state.realTimePower != nil || state.totalEnergy != nil else { return }
        queue.async { [self] in
            guard let db else { return }
            var stmt: OpaquePointer?
            let sql = "INSERT INTO samples (ts, device_id, power_w, total_kwh, run_kwh, indoor_c, target_c, is_on, mode) VALUES (?,?,?,?,?,?,?,?,?)"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, Int64(Date().timeIntervalSince1970))
            sqlite3_bind_int64(stmt, 2, Int64(bitPattern: deviceId))
            func bind(_ index: Int32, _ value: Double?) {
                if let value { sqlite3_bind_double(stmt, index, value) } else { sqlite3_bind_null(stmt, index) }
            }
            bind(3, state.realTimePower)
            bind(4, state.totalEnergy)
            bind(5, state.currentRunEnergy)
            bind(6, state.indoorTemperature)
            bind(7, state.targetTemperature)
            sqlite3_bind_int(stmt, 8, state.power ? 1 : 0)
            sqlite3_bind_int(stmt, 9, Int32(state.mode.rawValue))
            sqlite3_step(stmt)
        }
    }

    func summary(deviceId: UInt64) -> Summary {
        queue.sync {
            guard let db else { return Summary() }
            var summary = Summary()
            let cal = Calendar.current
            let startOfDay = Int64(cal.startOfDay(for: Date()).timeIntervalSince1970)
            let weekAgo = Int64(Date().addingTimeInterval(-7 * 86400).timeIntervalSince1970)
            let id = Int64(bitPattern: deviceId)

            func scalar(_ sql: String, _ binds: [Int64]) -> Double? {
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
                defer { sqlite3_finalize(stmt) }
                for (i, b) in binds.enumerated() { sqlite3_bind_int64(stmt, Int32(i + 1), b) }
                guard sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_type(stmt, 0) != SQLITE_NULL else { return nil }
                return sqlite3_column_double(stmt, 0)
            }
            summary.todayKWh = scalar("SELECT MAX(total_kwh) - MIN(total_kwh) FROM samples WHERE device_id = ? AND ts >= ? AND total_kwh IS NOT NULL", [id, startOfDay])
            summary.weekKWh = scalar("SELECT MAX(total_kwh) - MIN(total_kwh) FROM samples WHERE device_id = ? AND ts >= ? AND total_kwh IS NOT NULL", [id, weekAgo])
            summary.totalKWh = scalar("SELECT total_kwh FROM samples WHERE device_id = ? AND total_kwh IS NOT NULL ORDER BY ts DESC LIMIT 1", [id])
            summary.nowWatts = scalar("SELECT power_w FROM samples WHERE device_id = ? AND power_w IS NOT NULL ORDER BY ts DESC LIMIT 1", [id])
            summary.sampleCount = Int(scalar("SELECT COUNT(*) FROM samples WHERE device_id = ?", [id]) ?? 0)
            return summary
        }
    }
}
