import Foundation

enum SettingsSpeechHistoryIndex {
    private struct Day: Codable {
        let modifiedAt: Date
        let ids: [String]
        let metadata: [String: MetadataStamp]
    }
    private struct MetadataStamp: Codable, Equatable {
        let modifiedAt: Date
        let size: Int

        init?(entry: URL) {
            guard safeDirectory(entry), let file = safeFile(entry.appendingPathComponent("metadata.json")),
                  let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let modifiedAt = values.contentModificationDate, let size = values.fileSize else { return nil }
            self.modifiedAt = modifiedAt
            self.size = size
        }
    }
    private struct Source: Decodable { let source: String? }

    static func candidates(root: URL, metadataRead: (URL) -> Void) -> [URL] {
        guard !Task.isCancelled, safeDirectory(root) else { return [] }
        let manager = FileManager.default
        let index = URL(fileURLWithPath: root.path + ".speech-history-v1", isDirectory: true)
        if !manager.fileExists(atPath: index.path) {
            try? manager.createDirectory(at: index, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let usableIndex = safeDirectory(index)
        let checkpoint = index.appendingPathComponent(".days.json")
        let saved = (usableIndex ? safeFile(checkpoint) : nil).flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([String: Day].self, from: $0) } ?? [:]
        guard let days = try? manager.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return [] }
        var updated: [String: Day] = [:]
        var ids = Set<String>()
        for day in days {
            guard !Task.isCancelled else { return [] }
            let key = day.lastPathComponent
            guard key.range(of: #"^\d{4}-\d\d-\d\d$"#, options: .regularExpression) != nil,
                  safeDirectory(day),
                  let modified = try? day.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { continue }
            if let cached = saved[key], cached.modifiedAt == modified,
               cached.ids.allSatisfy({ validID($0) && $0.hasPrefix(key + "T") }),
               cached.metadata.allSatisfy({ id, stamp in
                   !Task.isCancelled && validID(id) && id.hasPrefix(key + "T") &&
                       MetadataStamp(entry: day.appendingPathComponent(id)) == stamp
               }) {
                updated[key] = cached
                ids.formUnion(cached.ids)
                continue
            }
            guard let entries = try? manager.contentsOfDirectory(at: day,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { continue }
            var speech: [String] = []
            var metadataStamps: [String: MetadataStamp] = [:]
            var readable = true
            for entry in entries {
                guard !Task.isCancelled else { return [] }
                let id = entry.lastPathComponent
                guard validID(id), id.hasPrefix(key + "T"), safeDirectory(entry) else { continue }
                let metadata = entry.appendingPathComponent("metadata.json")
                guard let stamp = MetadataStamp(entry: entry), let file = safeFile(metadata) else { readable = false; continue }
                metadataRead(file)
                guard let data = try? Data(contentsOf: file),
                      let source = try? JSONDecoder().decode(Source.self, from: data) else { readable = false; continue }
                metadataStamps[id] = stamp
                if source.source == "speak" { speech.append(id) }
            }
            ids.formUnion(speech)
            if readable { updated[key] = Day(modifiedAt: modified, ids: speech, metadata: metadataStamps) }
        }
        guard !Task.isCancelled else { return [] }
        if usableIndex, !Task.isCancelled, let data = try? JSONEncoder().encode(updated) {
            try? data.write(to: checkpoint, options: .atomic)
        }
        let markers = usableIndex ? (try? manager.contentsOfDirectory(at: index,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])) ?? [] : []
        ids.formUnion(markers.filter { validID($0.lastPathComponent) && safeFile($0) != nil }.map(\.lastPathComponent))
        return ids.sorted(by: >).compactMap { id in
            let day = root.appendingPathComponent(String(id.prefix(10)))
            let entry = day.appendingPathComponent(id)
            return safeDirectory(day) && safeDirectory(entry) ? entry : nil
        }
    }

    private static func validID(_ id: String) -> Bool {
        id.range(of: #"^\d{4}-\d\d-\d\dT\d\d-\d\d-\d\d-\d{3}Z-[a-f0-9]{8}$"#, options: .regularExpression) != nil
    }

    private static func safeDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private static func safeFile(_ url: URL) -> URL? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
        return url
    }
}
