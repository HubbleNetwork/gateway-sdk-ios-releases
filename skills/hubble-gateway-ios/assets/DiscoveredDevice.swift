import Foundation

struct DiscoveredDevice: Identifiable, Equatable {
    /// Device identity: the advertisement's service data payload.
    /// The CoreBluetooth peripheral identifier is NOT usable as a key —
    /// iOS re-mints it whenever the beacon rotates its advertised address,
    /// so one physical beacon would show up as many rows.
    let serviceData: Data
    var lastPeripheralId: UUID
    var lastServiceUUID: String
    var lastRSSI: Int
    let firstSeen: Date
    var lastSeen: Date
    var sightingCount: Int

    var id: Data { serviceData }
}
