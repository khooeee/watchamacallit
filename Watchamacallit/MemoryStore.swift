import Foundation

struct MemoryItem: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let content: String
    let createdAt: Date
}

actor MemoryStore {
    static let shared = MemoryStore()

    private var items: [MemoryItem] = []
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileURL: URL? = nil) {
        let directory = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first!
        self.fileURL = fileURL ?? directory.appendingPathComponent("memories.json")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        items = Self.load(from: self.fileURL, decoder: decoder)
    }

    func all() -> [MemoryItem] {
        items
    }

    func remember(content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Self.encode(["error": "Memory content was empty."])
        }

        let item = MemoryItem(
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
                "memories": [] as [Any]
            ])
        }

        let memories: [[String: String]] = items.map { item in
            [
                "id": item.id,
                "content": item.content,
                "createdAt": ISO8601DateFormatter().string(from: item.createdAt)
            ]
        }
        return Self.encode([
            "ok": true,
            "count": items.count,
            "memories": memories
        ])
    }

    func forget(id: String?, content: String?) -> String {
        let trimmedID = id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedContent = content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !trimmedID.isEmpty || !trimmedContent.isEmpty else {
            return Self.encode([
                "error": "Provide an id or content to forget a single memory."
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
                "error": "No matching memory found.",
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
            return "Stored memories: none."
        }

        let lines = items.enumerated().map { index, item in
            "\(index + 1). [\(item.id)] \(item.content)"
        }
        return """
        Stored memories (use these; call list_memories if you need IDs again):
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

    private static func load(from url: URL, decoder: JSONDecoder) -> [MemoryItem] {
        guard
            let data = try? Data(contentsOf: url),
            let items = try? decoder.decode([MemoryItem].self, from: data)
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
            return "{\"error\":\"Could not encode memory result.\"}"
        }
        return text
    }
}
