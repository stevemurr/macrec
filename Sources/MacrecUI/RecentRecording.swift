import Foundation

struct RecentRecording: Codable, Identifiable, Equatable {
    let id: UUID
    let appName: String
    let duration: TimeInterval
    let timestamp: Date
    let url: URL

    init(appName: String, duration: TimeInterval, timestamp: Date, url: URL) {
        self.id = UUID()
        self.appName = appName
        self.duration = duration
        self.timestamp = timestamp
        self.url = url
    }

    var displayName: String {
        "\(appName) · \(Self.format(duration: duration)) · \(Self.format(date: timestamp))"
    }

    var simpleDate: String {
        if Calendar.current.isDateInToday(timestamp) {
            return "Today"
        }
        if Calendar.current.isDateInYesterday(timestamp) {
            return "Yesterday"
        }
        let days = Calendar.current.dateComponents([.day], from: timestamp, to: Date()).day ?? 0
        if days < 7, let weekday = weekdayFormatter.string(for: timestamp) {
            return weekday
        }
        return shortDateFormatter.string(from: timestamp)
    }

    private static func format(duration: TimeInterval) -> String {
        let total = Int(duration)
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        let hours = total / 3600
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private static func format(date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }
}

private let weekdayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "EEEE"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter
}()

private let shortDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .none
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter
}()
