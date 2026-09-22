import Foundation

public struct MicrophonePriorityRow: Equatable {
    public let uid: String?
    public let deviceID: String?
    public let label: String
    public let isConnected: Bool

    public var canPrioritize: Bool {
        uid != nil
    }
}

public final class MicrophoneDevicePriority {
    private let defaults: UserDefaults
    private let orderKey: String
    private let labelsKey: String

    public init(
        defaults: UserDefaults,
        storageNamespace: String = "com.voicelayer.microphone-priority"
    ) {
        self.defaults = defaults
        orderKey = "\(storageNamespace).ordered-uids"
        labelsKey = "\(storageNamespace).known-labels"
    }

    public var preferredUIDs: [String] {
        Self.deduplicatedUIDs(defaults.stringArray(forKey: orderKey) ?? [])
    }

    public func observe(_ devices: [MicrophoneDevice]) {
        var labels = knownLabels
        for device in devices {
            guard let uid = Self.normalizedUID(device.uid) else { continue }
            labels[uid] = device.name
        }
        defaults.set(labels, forKey: labelsKey)
    }

    public func replacePreferredUIDs(
        _ uids: [String],
        observing devices: [MicrophoneDevice]
    ) {
        observe(devices)
        if uids.isEmpty {
            defaults.set([], forKey: orderKey)
            return
        }
        let knownUIDs = Set(knownLabels.keys)
        let validUIDs = Self.deduplicatedUIDs(uids).filter(knownUIDs.contains)
        guard !validUIDs.isEmpty else { return }
        defaults.set(validUIDs, forKey: orderKey)
    }

    public func rows(for devices: [MicrophoneDevice]) -> [MicrophonePriorityRow] {
        let connected = Self.connectedByUID(devices)
        let preferred = preferredUIDs
        let labels = knownLabels
        var rowUIDs = preferred
        var seenUIDs = Set(preferred)
        for device in devices {
            guard let uid = Self.normalizedUID(device.uid), seenUIDs.insert(uid).inserted else { continue }
            rowUIDs.append(uid)
        }
        rowUIDs.append(contentsOf: labels.keys
            .filter { !rowUIDs.contains($0) }
            .sorted { labels[$0, default: $0] < labels[$1, default: $1] })

        var rows = rowUIDs.map { uid in
            let device = connected[uid]
            return MicrophonePriorityRow(
                uid: uid,
                deviceID: device?.id,
                label: device?.name ?? labels[uid] ?? "Unknown Microphone",
                isConnected: device != nil
            )
        }
        rows.append(contentsOf: devices.compactMap { device in
            guard Self.normalizedUID(device.uid) == nil else { return nil }
            return MicrophonePriorityRow(
                uid: nil,
                deviceID: device.id,
                label: device.name,
                isConnected: true
            )
        })
        return rows
    }

    public func resolveDeviceID(
        in devices: [MicrophoneDevice],
        fallbackDeviceID: String?
    ) -> String? {
        let connected = Self.connectedByUID(devices)
        for uid in preferredUIDs {
            if let deviceID = connected[uid]?.id {
                return deviceID
            }
        }
        return fallbackDeviceID
    }

    private var knownLabels: [String: String] {
        defaults.dictionary(forKey: labelsKey) as? [String: String] ?? [:]
    }

    private static func connectedByUID(_ devices: [MicrophoneDevice]) -> [String: MicrophoneDevice] {
        var connected: [String: MicrophoneDevice] = [:]
        for device in devices {
            guard let uid = normalizedUID(device.uid), connected[uid] == nil else { continue }
            connected[uid] = device
        }
        return connected
    }

    private static func deduplicatedUIDs(_ uids: [String]) -> [String] {
        var seen = Set<String>()
        return uids.compactMap { value in
            guard let uid = normalizedUID(value), seen.insert(uid).inserted else { return nil }
            return uid
        }
    }

    private static func normalizedUID(_ uid: String?) -> String? {
        guard let value = uid?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
