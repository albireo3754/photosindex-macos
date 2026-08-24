import CryptoKit
import Foundation

public struct GeoPoint: Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

public struct GroupingAsset: Equatable, Sendable {
    public let id: String
    public let capturedAt: Date?
    public let coordinate: GeoPoint?

    public init(id: String, capturedAt: Date?, coordinate: GeoPoint?) {
        self.id = id
        self.capturedAt = capturedAt
        self.coordinate = coordinate
    }
}

public struct GroupingPolicy: Equatable, Sendable {
    public let maxGap: TimeInterval
    public let maxDistanceMeters: Double

    public init(maxGap: TimeInterval, maxDistanceMeters: Double) {
        self.maxGap = maxGap
        self.maxDistanceMeters = maxDistanceMeters
    }

    public static let coarseDefault = GroupingPolicy(maxGap: 120 * 60, maxDistanceMeters: 500)
    public static let fineDefault = GroupingPolicy(maxGap: 30 * 60, maxDistanceMeters: 200)
}

public struct CaptureSegment: Equatable, Sendable {
    public let id: String
    public let assetIDs: [String]
    public let warnings: [String]
}

public struct CaptureSession: Equatable, Sendable {
    public let id: String
    public let localDate: String
    public let assetIDs: [String]
    public let segments: [CaptureSegment]
}

public struct AssetGrouper: Sendable {
    public init() {}

    public func group(
        _ assets: [GroupingAsset],
        timezone: TimeZone,
        coarse: GroupingPolicy,
        fine: GroupingPolicy
    ) -> [CaptureSession] {
        let sorted = assets.sorted(by: sortAssets)
        let coarseGroups = partition(
            sorted,
            timezone: timezone,
            policy: coarse,
            nearbyMaxGap: coarse.maxGap
        )
        return coarseGroups.map { group in
            let date = localDate(group.first?.capturedAt, timezone: timezone)
            let sessionID = stableID(prefix: "session", date: date, ids: group.map(\.id))
            let segments = partition(
                group,
                timezone: timezone,
                policy: fine,
                nearbyMaxGap: coarse.maxGap
            ).map { segment in
                let warnings = segment.contains(where: { $0.coordinate == nil })
                    ? ["some_assets_without_location"] : []
                return CaptureSegment(
                    id: stableID(prefix: "segment", date: date, ids: segment.map(\.id)),
                    assetIDs: segment.map(\.id),
                    warnings: warnings
                )
            }
            return CaptureSession(
                id: sessionID,
                localDate: date,
                assetIDs: group.map(\.id),
                segments: segments
            )
        }
    }

    private func sortAssets(_ lhs: GroupingAsset, _ rhs: GroupingAsset) -> Bool {
        switch (lhs.capturedAt, rhs.capturedAt) {
        case let (left?, right?) where left != right:
            return left < right
        case (nil, _?):
            return false
        case (_?, nil):
            return true
        default:
            return lhs.id < rhs.id
        }
    }

    private func partition(
        _ assets: [GroupingAsset],
        timezone: TimeZone,
        policy: GroupingPolicy,
        nearbyMaxGap: TimeInterval
    ) -> [[GroupingAsset]] {
        guard let first = assets.first else { return [] }
        var output: [[GroupingAsset]] = [[first]]
        for asset in assets.dropFirst() {
            let previous = output[output.count - 1].last!
            if shouldSplit(
                previous,
                asset,
                timezone: timezone,
                policy: policy,
                nearbyMaxGap: nearbyMaxGap
            ) {
                output.append([asset])
            } else {
                output[output.count - 1].append(asset)
            }
        }
        return output
    }

    private func shouldSplit(
        _ lhs: GroupingAsset,
        _ rhs: GroupingAsset,
        timezone: TimeZone,
        policy: GroupingPolicy,
        nearbyMaxGap: TimeInterval
    ) -> Bool {
        guard let leftDate = lhs.capturedAt, let rightDate = rhs.capturedAt else {
            return lhs.capturedAt == nil || rhs.capturedAt == nil
        }
        if localDate(leftDate, timezone: timezone) != localDate(rightDate, timezone: timezone) {
            return true
        }
        let gap = rightDate.timeIntervalSince(leftDate)
        if let left = lhs.coordinate, let right = rhs.coordinate {
            if distance(from: left, to: right) > policy.maxDistanceMeters {
                return true
            }
            return gap > nearbyMaxGap
        }
        return gap > policy.maxGap
    }

    private func localDate(_ date: Date?, timezone: TimeZone) -> String {
        guard let date else { return "undated" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    private func distance(from lhs: GeoPoint, to rhs: GeoPoint) -> Double {
        let radius = 6_371_000.0
        let lat1 = lhs.latitude * .pi / 180
        let lat2 = rhs.latitude * .pi / 180
        let dLat = (rhs.latitude - lhs.latitude) * .pi / 180
        let dLon = (rhs.longitude - lhs.longitude) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return radius * 2 * atan2(sqrt(a), sqrt(1 - a))
    }

    private func stableID(prefix: String, date: String, ids: [String]) -> String {
        let digest = SHA256.hash(data: Data(ids.joined(separator: "\u{1f}").utf8))
        let suffix = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        return "\(prefix)_\(date.replacingOccurrences(of: "-", with: ""))_\(suffix)"
    }
}
