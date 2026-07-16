import Foundation
import HealthKit
import UserNotifications

/// Native capabilities exposed to mini-apps through the bridge. Every entry
/// point asks for its system permission on first use and returns a JSON-ready
/// dictionary with {ok, ...} so generated apps can handle denial gracefully.
enum MiniAppNotificationService {
    static func schedule(title: String, body: String, inSeconds: Double) async -> [String: Any] {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        guard granted else { return ["ok": false, "error": "permission_denied"] }

        let content = UNMutableNotificationContent()
        content.title = title.isEmpty ? "Mini-App" : String(title.prefix(80))
        content.body = String(body.prefix(300))
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, inSeconds), repeats: false)
        let id = "miniapp-\(UUID().uuidString)"
        do {
            try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
            return ["ok": true, "id": id]
        } catch {
            return ["ok": false, "error": error.localizedDescription]
        }
    }
}

enum MiniAppHealthService {
    static func query(type: String, days: Int) async -> [String: Any] {
        guard HKHealthStore.isHealthDataAvailable() else {
            return ["ok": false, "error": "health_unavailable"]
        }
        let (identifier, unit, options): (HKQuantityTypeIdentifier, HKUnit, HKStatisticsOptions)
        switch type {
        case "steps":
            (identifier, unit, options) = (.stepCount, .count(), .cumulativeSum)
        case "activeEnergy":
            (identifier, unit, options) = (.activeEnergyBurned, .kilocalorie(), .cumulativeSum)
        case "heartRate":
            (identifier, unit, options) = (.heartRate, HKUnit.count().unitDivided(by: .minute()), .discreteAverage)
        default:
            return ["ok": false, "error": "unknown_type"]
        }
        guard let quantityType = HKObjectType.quantityType(forIdentifier: identifier) else {
            return ["ok": false, "error": "unknown_type"]
        }

        let store = HKHealthStore()
        do {
            try await store.requestAuthorization(toShare: [], read: [quantityType])
        } catch {
            return ["ok": false, "error": error.localizedDescription]
        }

        let clampedDays = min(max(days, 1), 90)
        let calendar = Calendar.current
        let now = Date()
        guard let startDay = calendar.date(byAdding: .day, value: -(clampedDays - 1), to: now) else {
            return ["ok": false, "error": "bad_range"]
        }
        let start = calendar.startOfDay(for: startDay)

        let rows: [[String: Any]] = await withCheckedContinuation { continuation in
            let query = HKStatisticsCollectionQuery(
                quantityType: quantityType,
                quantitySamplePredicate: HKQuery.predicateForSamples(withStart: start, end: now, options: .strictStartDate),
                options: options,
                anchorDate: start,
                intervalComponents: DateComponents(day: 1)
            )
            query.initialResultsHandler = { _, collection, _ in
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd"
                var result: [[String: Any]] = []
                collection?.enumerateStatistics(from: start, to: now) { statistics, _ in
                    let value: Double
                    if options.contains(.cumulativeSum) {
                        value = statistics.sumQuantity()?.doubleValue(for: unit) ?? 0
                    } else {
                        value = statistics.averageQuantity()?.doubleValue(for: unit) ?? 0
                    }
                    result.append(["date": formatter.string(from: statistics.startDate), "value": value])
                }
                continuation.resume(returning: result)
            }
            store.execute(query)
        }
        return ["ok": true, "data": rows]
    }
}
