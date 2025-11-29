import Foundation

final class RecentsStore {
    private let defaultsKey = "macrec.recents"
    private let maxEntries = 5
    private let decoder = JSONDecoder()
    private let encoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes]
        return enc
    }()

    func load() -> [RecentRecording] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return [] }
        do {
            return try decoder.decode([RecentRecording].self, from: data)
        } catch {
            return []
        }
    }

    func add(_ entry: RecentRecording) -> [RecentRecording] {
        var current = load()
        current.insert(entry, at: 0)
        if current.count > maxEntries {
            current = Array(current.prefix(maxEntries))
        }
        if let data = try? encoder.encode(current) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
        return current
    }
}
