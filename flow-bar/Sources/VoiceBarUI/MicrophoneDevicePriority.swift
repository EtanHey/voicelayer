import Foundation

public struct MicrophonePriorityRow: Equatable {
    public let uid: String?
    public let deviceID: String?
    public let label: String
    public let isConnected: Bool
    public let isVirtualOrAggregateTransport: Bool?

    public init(uid: String?, deviceID: String?, label: String, isConnected: Bool,
                isVirtualOrAggregateTransport: Bool? = nil) {
        self.uid = uid
        self.deviceID = deviceID
        self.label = label
        self.isConnected = isConnected
        self.isVirtualOrAggregateTransport = isVirtualOrAggregateTransport
    }

    public var canPrioritize: Bool {
        uid != nil
    }

    public var isVirtualOrAggregate: Bool {
        if let isVirtualOrAggregateTransport { return isVirtualOrAggregateTransport }
        let identity = "\(uid ?? "") \(label)".lowercased()
        return ["cadefaultdeviceaggregate-", "aggregate", "virtual", "blackhole", "loopback"]
            .contains { identity.contains($0) }
    }
}

public struct MicrophonePrioritySnapshot: Equatable {
    public let rows: [MicrophonePriorityRow]
    public let nextDeviceName: String?
    public let nextDeviceUID: String?
    public let nextDeviceID: String?

    public init(
        rows: [MicrophonePriorityRow],
        nextDeviceName: String?,
        nextDeviceUID: String? = nil,
        nextDeviceID: String? = nil
    ) {
        self.rows = rows
        self.nextDeviceName = nextDeviceName
        self.nextDeviceUID = nextDeviceUID
        self.nextDeviceID = nextDeviceID
    }

    public static let unavailable = Self(rows: [], nextDeviceName: nil)

    public func reorderedUIDs(moving index: Int, by offset: Int) -> [String]? {
        let target = index + offset
        guard rows.indices.contains(index), rows.indices.contains(target),
              rows[index].canPrioritize, rows[target].canPrioritize
        else { return nil }
        var uids = rows.compactMap(\.uid)
        uids.swapAt(index, target)
        return uids
    }

    public var visibleRows: [MicrophonePriorityRow] {
        rows.filter { !$0.isVirtualOrAggregate }
    }

    public var nextVisibleDeviceName: String? {
        guard let nextDeviceName else { return nil }
        return nextDeviceIsHidden ? "Hidden microphone selected" : nextDeviceName
    }

    /// Matches the next device by identity (UID, then device ID) so a hidden aggregate that shares a physical
    /// mic's name never hides it; the label is only a fallback for callers that know no identity.
    public var nextDeviceIsHidden: Bool {
        if nextDeviceUID != nil || nextDeviceID != nil {
            return rows.contains { row in
                row.isVirtualOrAggregate
                    && ((nextDeviceUID != nil && row.uid == nextDeviceUID)
                        || (nextDeviceID != nil && row.deviceID == nextDeviceID))
            }
        }
        guard let nextDeviceName else { return false }
        return rows.contains { $0.label == nextDeviceName && $0.isVirtualOrAggregate }
    }

    /// The saved order with every visible device ahead of the hidden ones (relative order kept), offered
    /// only while a hidden device would be used next. nil when there is nothing to fix.
    public var visibleFirstUIDs: [String]? {
        guard nextDeviceIsHidden, !visibleRows.isEmpty else { return nil }
        return visibleRows.compactMap(\.uid) + rows.filter(\.isVirtualOrAggregate).compactMap(\.uid)
    }

    public func reorderedVisibleUIDs(moving index: Int, by offset: Int) -> [String]? {
        let visible = visibleRows
        let target = index + offset
        guard visible.indices.contains(index), visible.indices.contains(target),
              let sourceUID = visible[index].uid, let targetUID = visible[target].uid
        else { return nil }
        var visibleUIDs = visible.compactMap(\.uid)
        guard let source = visibleUIDs.firstIndex(of: sourceUID),
              let destination = visibleUIDs.firstIndex(of: targetUID)
        else { return nil }
        visibleUIDs.swapAt(source, destination)
        return visibleUIDs + rows.filter(\.isVirtualOrAggregate).compactMap(\.uid)
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
                isConnected: device != nil,
                isVirtualOrAggregateTransport: device?.isVirtualOrAggregateTransport
            )
        }
        rows.append(contentsOf: devices.compactMap { device in
            guard Self.normalizedUID(device.uid) == nil else { return nil }
            return MicrophonePriorityRow(
                uid: nil,
                deviceID: device.id,
                label: device.name,
                isConnected: true,
                isVirtualOrAggregateTransport: device.isVirtualOrAggregateTransport
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
