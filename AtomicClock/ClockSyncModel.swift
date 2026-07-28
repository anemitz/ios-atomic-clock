// SPDX-License-Identifier: Elastic-2.0

import Foundation
import Observation

@MainActor
@Observable
final class ClockSyncModel {
    private let timeClient: any NetworkTimeSampling
    private let servers: [String]

    private(set) var clockOffset: TimeInterval = 0
    private(set) var syncState: SyncState = .idle
    private(set) var lastSynchronization: TimeSynchronization?
    private(set) var serverSamples: [NTPServerSample] = []

    init(
        timeClient: any NetworkTimeSampling = NetworkTimeClient(),
        servers: [String] = NetworkTimeClient.defaultServers
    ) {
        self.timeClient = timeClient
        self.servers = servers
    }

    var isSyncing: Bool {
        if case .syncing = syncState {
            return true
        }
        return false
    }

    func startAutomaticSynchronization() async {
        await synchronize()

        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(300))
            } catch {
                return
            }

            await synchronize()
        }
    }

    func synchronize() async {
        guard !isSyncing else {
            return
        }

        syncState = .syncing

        let samples = await timeClient.samples(from: servers)
        serverSamples = samples

        let measurements = samples.compactMap(\.measurement)
        guard !measurements.isEmpty else {
            syncState = .failed("No NTP response")
            return
        }

        let fastestMeasurements = Array(
            measurements
                .sorted { $0.roundTripDelay < $1.roundTripDelay }
                .prefix(3)
        )
        let primary = fastestMeasurements[0]
        let selectedOffset = medianOffset(from: fastestMeasurements)

        clockOffset = selectedOffset
        lastSynchronization = TimeSynchronization(
            offset: selectedOffset,
            source: fastestMeasurements.count == 1 ? primary.server : "Median of \(fastestMeasurements.count) fastest",
            primaryServer: primary.server,
            roundTripDelay: primary.roundTripDelay,
            reachableServers: measurements.count,
            totalServers: servers.count
        )
        syncState = .synced
    }

    private func medianOffset(from measurements: [NTPMeasurement]) -> TimeInterval {
        let offsets = measurements.map(\.offset).sorted()
        let middleIndex = offsets.count / 2

        if offsets.count.isMultiple(of: 2) {
            return (offsets[middleIndex - 1] + offsets[middleIndex]) / 2
        }

        return offsets[middleIndex]
    }
}

enum SyncState: Equatable {
    case idle
    case syncing
    case synced
    case failed(String)
}

struct TimeSynchronization: Equatable {
    let offset: TimeInterval
    let source: String
    let primaryServer: String
    let roundTripDelay: TimeInterval
    let reachableServers: Int
    let totalServers: Int
}
