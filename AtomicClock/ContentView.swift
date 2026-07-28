// SPDX-License-Identifier: Elastic-2.0

import SwiftUI

struct ContentView: View {
    @State private var syncModel = ClockSyncModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    TimelineView(.periodic(from: .now, by: 0.1)) { context in
                        ClockStack(date: context.date.addingTimeInterval(syncModel.clockOffset))
                    }

                    SyncStatusPanel(model: syncModel)
                    ServerSamplesPanel(samples: syncModel.serverSamples)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 20)
            }
            .refreshable {
                await syncModel.synchronize()
            }
            .background(AppBackground())
            .navigationTitle("Atomic Clock")
        }
        .task {
            await syncModel.startAutomaticSynchronization()
        }
    }
}

private struct ClockStack: View {
    let date: Date

    var body: some View {
        VStack(spacing: 12) {
            ClockCard(
                title: "UTC",
                subtitle: "Coordinated Universal Time",
                systemImage: "globe",
                tint: .green,
                time: formattedTime(date, timeZone: TimeZone(secondsFromGMT: 0)!)
            )

            ClockCard(
                title: "Local",
                subtitle: TimeZone.current.identifier,
                systemImage: "iphone",
                tint: .blue,
                time: formattedTime(date, timeZone: .current)
            )
        }
    }

    private func formattedTime(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.hour, .minute, .second], from: date)
        return String(
            format: "%02d:%02d:%02d",
            components.hour ?? 0,
            components.minute ?? 0,
            components.second ?? 0
        )
    }
}

private struct ClockCard: View {
    @Environment(\.colorScheme) private var colorScheme

    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    let time: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.headline)
                    .foregroundStyle(tint)
                    .frame(width: 28, height: 28)
                    .background(
                        tint.opacity(colorScheme == .dark ? 0.22 : 0.12),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }

            Text(time)
                .font(.system(size: 58, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .contentTransition(.numericText())
                .accessibilityLabel("\(title) time \(time)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSurface(padding: 18)
    }
}

private struct SyncStatusPanel: View {
    let model: ClockSyncModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                statusIcon
                    .font(.headline)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(statusDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            if let synchronization = model.lastSynchronization {
                Divider()

                HStack(spacing: 12) {
                    MetricView(title: "Offset", value: formattedOffset(synchronization.offset))
                    MetricView(title: "Delay", value: formattedMilliseconds(synchronization.roundTripDelay))
                    MetricView(
                        title: "Servers",
                        value: "\(synchronization.reachableServers)/\(synchronization.totalServers)"
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSurface(padding: 16)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch model.syncState {
        case .idle:
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
        case .syncing:
            ProgressView()
        case .synced:
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    private var statusTitle: String {
        switch model.syncState {
        case .idle:
            return "Waiting to sync"
        case .syncing:
            return "Syncing"
        case .synced:
            return "Synced"
        case .failed:
            return "Sync failed"
        }
    }

    private var statusDetail: String {
        switch model.syncState {
        case .idle:
            return "Phone time"
        case .syncing:
            return "Querying NTP servers"
        case .synced:
            guard let synchronization = model.lastSynchronization else {
                return "NTP adjusted"
            }
            return "\(synchronization.source) · \(synchronization.primaryServer)"
        case .failed(let message):
            return message
        }
    }
}

private struct MetricView: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ServerSamplesPanel: View {
    let samples: [NTPServerSample]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("NTP Servers")
                .font(.headline)
                .foregroundStyle(.primary)

            if samples.isEmpty {
                Text("No samples yet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } else {
                ForEach(samples) { sample in
                    ServerSampleRow(sample: sample)

                    if sample.id != samples.last?.id {
                        Divider()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSurface(padding: 16)
    }
}

private struct ServerSampleRow: View {
    let sample: NTPServerSample

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: sample.isSuccessful ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(sample.isSuccessful ? .green : .orange)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(sample.server)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            Spacer(minLength: 8)
        }
        .accessibilityElement(children: .combine)
    }

    private var detailText: String {
        if let measurement = sample.measurement {
            return
                "\(formattedOffset(measurement.offset)) · \(formattedMilliseconds(measurement.roundTripDelay)) · stratum \(measurement.stratum)"
        }

        return sample.errorDescription ?? "Unavailable"
    }
}

private struct AppBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        LinearGradient(
            colors: colors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    private var colors: [Color] {
        if colorScheme == .dark {
            return [
                Color(red: 0.035, green: 0.050, blue: 0.060),
                Color(red: 0.060, green: 0.075, blue: 0.095),
                Color(red: 0.025, green: 0.085, blue: 0.080),
            ]
        }

        return [
            Color(red: 0.92, green: 0.96, blue: 0.94),
            Color(red: 0.96, green: 0.97, blue: 0.99),
            Color(red: 0.90, green: 0.93, blue: 0.98),
        ]
    }
}

private struct PanelSurfaceStyle: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    let padding: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(border, lineWidth: 1)
            }
            .shadow(color: shadow, radius: colorScheme == .dark ? 0 : 14, x: 0, y: 8)
    }

    private var fill: Color {
        colorScheme == .dark
            ? Color(red: 0.105, green: 0.125, blue: 0.145).opacity(0.92)
            : Color.white.opacity(0.74)
    }

    private var border: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.10)
            : Color.black.opacity(0.08)
    }

    private var shadow: Color {
        colorScheme == .dark
            ? Color.clear
            : Color.black.opacity(0.06)
    }
}

extension View {
    fileprivate func panelSurface(padding: CGFloat) -> some View {
        modifier(PanelSurfaceStyle(padding: padding))
    }
}

private func formattedOffset(_ value: TimeInterval) -> String {
    let milliseconds = value * 1_000
    if abs(milliseconds) < 0.05 {
        return "0.0 ms"
    }

    return String(format: "%+.1f ms", milliseconds)
}

private func formattedMilliseconds(_ value: TimeInterval) -> String {
    String(format: "%.0f ms", value * 1_000)
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            ContentView()
                .preferredColorScheme(.light)

            ContentView()
                .preferredColorScheme(.dark)
        }
    }
}
