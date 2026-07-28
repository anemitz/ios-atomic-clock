// SPDX-License-Identifier: Elastic-2.0

import Foundation
import Network

protocol NetworkTimeSampling: Sendable {
    func samples(from servers: [String]) async -> [NTPServerSample]
}

struct NetworkTimeClient: NetworkTimeSampling {
    static let defaultServers = [
        "time.apple.com",
        "time.google.com",
        "time.cloudflare.com",
        "pool.ntp.org",
        "time.nist.gov",
    ]

    let timeout: TimeInterval

    init(timeout: TimeInterval = 2.0) {
        self.timeout = timeout.isFinite ? min(max(0.1, timeout), 60.0) : 2.0
    }

    func samples(from servers: [String]) async -> [NTPServerSample] {
        await withTaskGroup(of: NTPServerSample.self) { group in
            for server in servers {
                group.addTask {
                    await sample(from: server)
                }
            }

            var samples: [NTPServerSample] = []
            for await sample in group {
                samples.append(sample)
            }

            return samples.sorted { lhs, rhs in
                let lhsIndex = servers.firstIndex(of: lhs.server) ?? Int.max
                let rhsIndex = servers.firstIndex(of: rhs.server) ?? Int.max
                return lhsIndex < rhsIndex
            }
        }
    }

    private func sample(from server: String) async -> NTPServerSample {
        do {
            let measurement = try await measurement(from: server)
            return NTPServerSample(server: server, measurement: measurement, errorDescription: nil)
        } catch {
            return NTPServerSample(
                server: server,
                measurement: nil,
                errorDescription: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
        }
    }

    private func measurement(from server: String) async throws -> NTPMeasurement {
        let connection = NWConnection(host: NWEndpoint.Host(server), port: 123, using: .udp)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let completion = NTPRequestCompletion(
                    connection: connection,
                    continuation: continuation
                )
                let queue = DispatchQueue(label: "AtomicClock.NTP.\(server)", qos: .userInitiated)

                let timeoutMilliseconds = Int((timeout * 1_000).rounded(.up))
                queue.asyncAfter(deadline: .now() + .milliseconds(timeoutMilliseconds)) {
                    completion.fail(NTPClientError.timeout)
                }

                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        let sentAt = Date()
                        let request = NTPPacket.request(transmitDate: sentAt)

                        connection.send(
                            content: request,
                            completion: .contentProcessed { error in
                                if let error {
                                    completion.fail(NTPClientError.network(error.localizedDescription))
                                    return
                                }

                                connection.receiveMessage { data, _, _, error in
                                    let receivedAt = Date()

                                    if let error {
                                        completion.fail(NTPClientError.network(error.localizedDescription))
                                        return
                                    }

                                    guard let data else {
                                        completion.fail(NTPClientError.emptyResponse)
                                        return
                                    }

                                    do {
                                        let measurement = try NTPPacket.measurement(
                                            from: data,
                                            matching: request,
                                            server: server,
                                            localTransmit: sentAt,
                                            localReceive: receivedAt
                                        )
                                        completion.succeed(measurement)
                                    } catch {
                                        completion.fail(error)
                                    }
                                }
                            })

                    case .failed(let error):
                        completion.fail(NTPClientError.network(error.localizedDescription))

                    case .cancelled:
                        completion.fail(CancellationError())

                    default:
                        break
                    }
                }

                guard !Task.isCancelled else {
                    completion.fail(CancellationError())
                    return
                }

                connection.start(queue: queue)
            }
        } onCancel: {
            connection.cancel()
        }
    }
}

struct NTPServerSample: Identifiable, Sendable {
    let id = UUID()
    let server: String
    let measurement: NTPMeasurement?
    let errorDescription: String?

    var isSuccessful: Bool {
        measurement != nil
    }
}

struct NTPMeasurement: Sendable {
    let server: String
    let offset: TimeInterval
    let roundTripDelay: TimeInterval
    let stratum: Int
    let receivedAt: Date
}

enum NTPClientError: LocalizedError, Sendable {
    case timeout
    case emptyResponse
    case invalidResponse
    case invalidVersion(Int)
    case invalidMode(Int)
    case mismatchedResponse
    case unsynchronizedServer
    case network(String)

    var errorDescription: String? {
        switch self {
        case .timeout:
            return "Timed out"
        case .emptyResponse:
            return "Empty response"
        case .invalidResponse:
            return "Invalid NTP response"
        case .invalidVersion(let version):
            return "Unsupported NTP version \(version)"
        case .invalidMode(let mode):
            return "Unexpected NTP mode \(mode)"
        case .mismatchedResponse:
            return "NTP response did not match the request"
        case .unsynchronizedServer:
            return "Server is unsynchronized"
        case .network(let message):
            return message
        }
    }
}

private final class NTPRequestCompletion: @unchecked Sendable {
    private let connection: NWConnection
    private let continuation: CheckedContinuation<NTPMeasurement, Error>
    private let lock = NSLock()
    private var hasCompleted = false

    init(connection: NWConnection, continuation: CheckedContinuation<NTPMeasurement, Error>) {
        self.connection = connection
        self.continuation = continuation
    }

    func succeed(_ measurement: NTPMeasurement) {
        complete(.success(measurement))
    }

    func fail(_ error: Error) {
        complete(.failure(error))
    }

    private func complete(_ result: Result<NTPMeasurement, Error>) {
        lock.lock()
        guard !hasCompleted else {
            lock.unlock()
            return
        }
        hasCompleted = true
        lock.unlock()

        connection.stateUpdateHandler = nil
        connection.cancel()

        switch result {
        case .success(let measurement):
            continuation.resume(returning: measurement)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

enum NTPPacket {
    private static let ntpEpochOffset: TimeInterval = 2_208_988_800
    private static let fractionalScale = Double(UInt64(UInt32.max) + 1)

    static func request(transmitDate: Date) -> Data {
        var data = Data(repeating: 0, count: 48)
        data[0] = 0x23
        writeTimestamp(transmitDate, into: &data, at: 40)
        return data
    }

    static func measurement(
        from data: Data,
        matching request: Data,
        server: String,
        localTransmit: Date,
        localReceive: Date
    ) throws -> NTPMeasurement {
        guard data.count >= 48, request.count >= 48 else {
            throw NTPClientError.invalidResponse
        }

        let leapIndicator = (data[0] >> 6) & 0x03
        let version = Int((data[0] >> 3) & 0x07)
        let mode = Int(data[0] & 0x07)
        let stratum = Int(data[1])

        guard (3...4).contains(version) else {
            throw NTPClientError.invalidVersion(version)
        }

        guard leapIndicator != 3, (1...15).contains(stratum) else {
            throw NTPClientError.unsynchronizedServer
        }

        guard mode == 4 else {
            throw NTPClientError.invalidMode(mode)
        }

        guard data[24..<32].elementsEqual(request[40..<48]) else {
            throw NTPClientError.mismatchedResponse
        }

        let serverReceive = try readTimestamp(from: data, at: 32, near: localReceive)
        let serverTransmit = try readTimestamp(from: data, at: 40, near: localReceive)

        guard serverTransmit >= serverReceive else {
            throw NTPClientError.invalidResponse
        }

        let t1 = localTransmit.timeIntervalSince1970
        let t2 = serverReceive.timeIntervalSince1970
        let t3 = serverTransmit.timeIntervalSince1970
        let t4 = localReceive.timeIntervalSince1970

        let offset = ((t2 - t1) + (t3 - t4)) / 2
        let delay = max(0, (t4 - t1) - (t3 - t2))

        return NTPMeasurement(
            server: server,
            offset: offset,
            roundTripDelay: delay,
            stratum: stratum,
            receivedAt: localReceive
        )
    }

    private static func readTimestamp(
        from data: Data,
        at index: Int,
        near referenceDate: Date
    ) throws -> Date {
        guard data.count >= index + 8 else {
            throw NTPClientError.invalidResponse
        }

        let seconds = readUInt32(from: data, at: index)
        let fraction = readUInt32(from: data, at: index + 4)

        guard seconds != 0 || fraction != 0 else {
            throw NTPClientError.invalidResponse
        }

        let timestampWithinEra = Double(seconds) + Double(fraction) / fractionalScale
        let referenceNTPInterval = referenceDate.timeIntervalSince1970 + ntpEpochOffset
        let era = ((referenceNTPInterval - timestampWithinEra) / fractionalScale).rounded()
        let interval = timestampWithinEra + era * fractionalScale - ntpEpochOffset
        return Date(timeIntervalSince1970: interval)
    }

    private static func writeTimestamp(_ date: Date, into data: inout Data, at index: Int) {
        let ntpInterval = date.timeIntervalSince1970 + ntpEpochOffset
        let seconds = floor(ntpInterval)
        let fraction = ntpInterval - seconds
        let fractionValue = min(fraction * fractionalScale, fractionalScale - 1)
        let secondsWithinEra = seconds.truncatingRemainder(dividingBy: fractionalScale)

        writeUInt32(UInt32(secondsWithinEra), into: &data, at: index)
        writeUInt32(UInt32(fractionValue), into: &data, at: index + 4)
    }

    private static func readUInt32(from data: Data, at index: Int) -> UInt32 {
        var value: UInt32 = 0
        for byte in 0..<4 {
            value = (value << 8) | UInt32(data[index + byte])
        }
        return value
    }

    private static func writeUInt32(_ value: UInt32, into data: inout Data, at index: Int) {
        for byte in 0..<4 {
            let shift = UInt32((3 - byte) * 8)
            data[index + byte] = UInt8((value >> shift) & 0xff)
        }
    }
}
