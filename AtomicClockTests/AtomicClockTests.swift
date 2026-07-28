// SPDX-License-Identifier: Elastic-2.0

import XCTest

@testable import AtomicClock

final class NTPPacketTests: XCTestCase {
    func testRequestUsesNTPVersionFourClientMode() {
        let request = NTPPacket.request(transmitDate: Date(timeIntervalSince1970: 1_700_000_000))

        XCTAssertEqual(request.count, 48)
        XCTAssertEqual((request[0] >> 3) & 0x07, 4)
        XCTAssertEqual(request[0] & 0x07, 3)
        XCTAssertNotEqual(Data(request[40..<48]), Data(repeating: 0, count: 8))
    }

    func testMeasurementCalculatesOffsetAndRoundTripDelay() throws {
        let localTransmit = Date(timeIntervalSince1970: 1_700_000_000)
        let localReceive = localTransmit.addingTimeInterval(0.045)
        let request = NTPPacket.request(transmitDate: localTransmit)
        let response = response(
            matching: request,
            serverReceive: localTransmit.addingTimeInterval(0.120),
            serverTransmit: localTransmit.addingTimeInterval(0.125)
        )

        let measurement = try NTPPacket.measurement(
            from: response,
            matching: request,
            server: "time.example.com",
            localTransmit: localTransmit,
            localReceive: localReceive
        )

        XCTAssertEqual(measurement.offset, 0.100, accuracy: 0.000_001)
        XCTAssertEqual(measurement.roundTripDelay, 0.040, accuracy: 0.000_001)
        XCTAssertEqual(measurement.stratum, 2)
    }

    func testMeasurementUnfoldsTimestampsAfterThe2036EraRollover() throws {
        let localTransmit = Date(timeIntervalSince1970: 2_100_000_000)
        let localReceive = localTransmit.addingTimeInterval(0.045)
        let request = NTPPacket.request(transmitDate: localTransmit)
        let response = response(
            matching: request,
            serverReceive: localTransmit.addingTimeInterval(0.120),
            serverTransmit: localTransmit.addingTimeInterval(0.125)
        )

        let measurement = try NTPPacket.measurement(
            from: response,
            matching: request,
            server: "time.example.com",
            localTransmit: localTransmit,
            localReceive: localReceive
        )

        XCTAssertEqual(measurement.offset, 0.100, accuracy: 0.000_001)
        XCTAssertEqual(measurement.roundTripDelay, 0.040, accuracy: 0.000_001)
    }

    func testMeasurementRejectsAResponseForAnotherRequest() {
        let localTransmit = Date(timeIntervalSince1970: 1_700_000_000)
        let request = NTPPacket.request(transmitDate: localTransmit)
        let otherRequest = NTPPacket.request(transmitDate: localTransmit.addingTimeInterval(1))
        let response = response(
            matching: otherRequest,
            serverReceive: localTransmit.addingTimeInterval(0.020),
            serverTransmit: localTransmit.addingTimeInterval(0.025)
        )

        XCTAssertThrowsError(
            try NTPPacket.measurement(
                from: response,
                matching: request,
                server: "time.example.com",
                localTransmit: localTransmit,
                localReceive: localTransmit.addingTimeInterval(0.045)
            )
        ) { error in
            guard case NTPClientError.mismatchedResponse = error else {
                return XCTFail("Expected mismatchedResponse, got \(error)")
            }
        }
    }

    private func response(
        matching request: Data,
        serverReceive: Date,
        serverTransmit: Date
    ) -> Data {
        var response = Data(repeating: 0, count: 48)
        response[0] = 0x24
        response[1] = 2
        response.replaceSubrange(24..<32, with: request[40..<48])
        writeTimestamp(serverReceive, into: &response, at: 32)
        writeTimestamp(serverTransmit, into: &response, at: 40)
        return response
    }

    private func writeTimestamp(_ date: Date, into data: inout Data, at index: Int) {
        let ntpInterval = date.timeIntervalSince1970 + 2_208_988_800
        let wholeSeconds = floor(ntpInterval)
        let fractionalScale = Double(UInt64(UInt32.max) + 1)
        let fraction = UInt32((ntpInterval - wholeSeconds) * fractionalScale)
        let secondsWithinEra = wholeSeconds.truncatingRemainder(dividingBy: fractionalScale)

        writeUInt32(UInt32(secondsWithinEra), into: &data, at: index)
        writeUInt32(fraction, into: &data, at: index + 4)
    }

    private func writeUInt32(_ value: UInt32, into data: inout Data, at index: Int) {
        for byte in 0..<4 {
            let shift = UInt32((3 - byte) * 8)
            data[index + byte] = UInt8((value >> shift) & 0xff)
        }
    }
}

@MainActor
final class ClockSyncModelTests: XCTestCase {
    func testSynchronizationUsesMedianOfTheThreeFastestServers() async {
        let samples = [
            sample(server: "slow.example.com", offset: 4.0, delay: 0.400),
            sample(server: "fast-a.example.com", offset: -0.200, delay: 0.010),
            sample(server: "fast-b.example.com", offset: 0.100, delay: 0.020),
            sample(server: "fast-c.example.com", offset: 0.300, delay: 0.030),
        ]
        let servers = samples.map(\.server)
        let model = ClockSyncModel(timeClient: StubTimeClient(samples: samples), servers: servers)

        await model.synchronize()

        XCTAssertEqual(model.clockOffset, 0.100, accuracy: 0.000_001)
        XCTAssertEqual(model.syncState, .synced)
        XCTAssertEqual(model.lastSynchronization?.reachableServers, 4)
        XCTAssertEqual(model.lastSynchronization?.totalServers, 4)
        XCTAssertEqual(model.lastSynchronization?.primaryServer, "fast-a.example.com")
    }

    func testSynchronizationFailsWhenEveryServerIsUnavailable() async {
        let samples = [
            NTPServerSample(
                server: "offline.example.com",
                measurement: nil,
                errorDescription: "Timed out"
            )
        ]
        let model = ClockSyncModel(
            timeClient: StubTimeClient(samples: samples),
            servers: ["offline.example.com"]
        )

        await model.synchronize()

        XCTAssertEqual(model.clockOffset, 0)
        XCTAssertEqual(model.syncState, .failed("No NTP response"))
        XCTAssertNil(model.lastSynchronization)
    }

    private func sample(
        server: String,
        offset: TimeInterval,
        delay: TimeInterval
    ) -> NTPServerSample {
        NTPServerSample(
            server: server,
            measurement: NTPMeasurement(
                server: server,
                offset: offset,
                roundTripDelay: delay,
                stratum: 2,
                receivedAt: Date()
            ),
            errorDescription: nil
        )
    }
}

private struct StubTimeClient: NetworkTimeSampling {
    let samples: [NTPServerSample]

    func samples(from servers: [String]) async -> [NTPServerSample] {
        samples
    }
}
