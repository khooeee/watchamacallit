import Foundation

struct ReminderItem: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let content: String
    let createdAt: Date
}

actor ReminderStore {
    static let shared = ReminderStore()

    private var items: [ReminderItem] = []
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileURL: URL? = nil) {
        let directory = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first!
        let remindersURL = directory.appendingPathComponent("reminders.json")
        self.fileURL = fileURL ?? remindersURL

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        if fileURL == nil {
            items = Self.loadMigrating(
                to: remindersURL,
                legacyURL: directory.appendingPathComponent("memories.json"),
                decoder: decoder
            )
        } else {
            items = Self.load(from: self.fileURL, decoder: decoder)
        }
    }

    func all() -> [ReminderItem] {
        items
    }

    func remind(content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Self.encode(["error": "Reminder content was empty."])
        }

        let item = ReminderItem(
            id: UUID().uuidString,
            content: trimmed,
            createdAt: Date()
        )
        items.append(item)
        persist()
        return Self.encode([
            "ok": true,
            "id": item.id,
            "content": item.content,
            "count": items.count
        ])
    }

    func list() -> String {
        if items.isEmpty {
            return Self.encode([
                "ok": true,
                "count": 0,
                "reminders": [] as [Any]
            ])
        }

        let reminders: [[String: String]] = items.map { item in
            [
                "id": item.id,
                "content": item.content,
                "createdAt": ISO8601DateFormatter().string(from: item.createdAt)
            ]
        }
        return Self.encode([
            "ok": true,
            "count": items.count,
            "reminders": reminders
        ])
    }

    func forget(id: String?, content: String?) -> String {
        let trimmedID = id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedContent = content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !trimmedID.isEmpty || !trimmedContent.isEmpty else {
            return Self.encode([
                "error": "Provide an id or content to forget a single reminder."
            ])
        }

        let matchIndex: Int?
        if !trimmedID.isEmpty {
            matchIndex = items.firstIndex { $0.id == trimmedID }
        } else {
            let needle = trimmedContent.lowercased()
            matchIndex = items.firstIndex {
                $0.content.lowercased() == needle
                    || $0.content.lowercased().contains(needle)
            }
        }

        guard let matchIndex else {
            return Self.encode([
                "ok": false,
                "error": "No matching reminder found.",
                "count": items.count
            ])
        }

        let removed = items.remove(at: matchIndex)
        persist()
        return Self.encode([
            "ok": true,
            "removed": [
                "id": removed.id,
                "content": removed.content
            ],
            "count": items.count
        ])
    }

    func clear() -> String {
        let removed = items.count
        items = []
        persist()
        return Self.encode([
            "ok": true,
            "cleared": removed,
            "count": 0
        ])
    }

    func instructionsBlock() -> String {
        guard !items.isEmpty else {
            return "Stored reminders: none."
        }

        let lines = items.enumerated().map { index, item in
            "\(index + 1). [\(item.id)] \(item.content)"
        }
        return """
        Stored reminders (use these; call list_reminders if you need them again):
        \(lines.joined(separator: "\n"))
        """
    }

    private func persist() {
        do {
            let data = try encoder.encode(items)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            // Keep in-memory state; next mutation retries disk write.
        }
    }

    private static func loadMigrating(
        to url: URL,
        legacyURL: URL,
        decoder: JSONDecoder
    ) -> [ReminderItem] {
        if FileManager.default.fileExists(atPath: url.path) {
            return load(from: url, decoder: decoder)
        }

        let legacyItems = load(from: legacyURL, decoder: decoder)
        guard !legacyItems.isEmpty else {
            return []
        }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(legacyItems)
            try data.write(to: url, options: [.atomic])
            try? FileManager.default.removeItem(at: legacyURL)
        } catch {
            // Fall through with loaded legacy items; persist() will retry later.
        }
        return legacyItems
    }

    private static func load(from url: URL, decoder: JSONDecoder) -> [ReminderItem] {
        guard
            let data = try? Data(contentsOf: url),
            let items = try? decoder.decode([ReminderItem].self, from: data)
        else {
            return []
        }
        return items
    }

    static func encode(_ object: Any) -> String {
        guard
            JSONSerialization.isValidJSONObject(object),
            let data = try? JSONSerialization.data(withJSONObject: object),
            let text = String(data: data, encoding: .utf8)
        else {
            return "{\"error\":\"Could not encode reminder result.\"}"
        }
        return text
    }
}
