// SwiftUI views for an OutcomeReport and a PipelineHealth snapshot.
//
// Pure presentation: every view takes plain values from the core module and
// owns no state, so a host app (or a preview) decides where the numbers come
// from. The module builds to nothing on platforms without SwiftUI (Linux CI).

#if canImport(SwiftUI)
import Foundation
import OutcomeTelemetry
import SwiftUI

/// Formatting helpers shared by the views. Kept internal and pure.
enum Format {
    static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.1f%%", value * 100)
    }

    static func points(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%+.1f pts", value * 100)
    }

    static func interval(_ range: ClosedRange<Double>?) -> String {
        guard let range else { return "not enough data" }
        return String(format: "95%% CI %+.1f to %+.1f pts", range.lowerBound * 100, range.upperBound * 100)
    }

    static func bound(_ bound: QuantileBound?) -> String { bound?.label ?? "—" }

    static func exposure(_ exposure: AIExposure) -> String {
        switch exposure {
        case .none: return "not shown"
        case .shownOnly: return "shown, not used"
        case .edited: return "used after editing"
        case .accepted: return "used as offered"
        }
    }
}

/// The report for one task kind: the causal comparison first, the
/// confounded exposure split second and labelled as such.
public struct OutcomeDashboard: View {
    private let report: OutcomeReport
    private let featureName: String

    public init(report: OutcomeReport, featureName: String) {
        self.report = report
        self.featureName = featureName
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headline
            armsTable
            exposureTable
            privacyNote
            FunnelView(dropOff: report.dropOff, noStepReached: report.noStepReached)
        }
    }

    private var verdictColor: Color {
        switch report.comparison.verdict {
        case .treatmentBetter: return .green
        case .treatmentWorse: return .red
        case .inconclusive: return .orange
        case .insufficientData: return .secondary
        }
    }

    private var verdictText: String {
        switch report.comparison.verdict {
        case .treatmentBetter: return "helps"
        case .treatmentWorse: return "hurts"
        case .inconclusive: return "no clear effect"
        case .insufficientData: return "not enough data yet"
        }
    }

    private var headline: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(featureName): \(verdictText)")
                .font(.title3.bold())
                .foregroundStyle(verdictColor)
            Text("Completion, AI on vs. holdout: \(Format.points(report.comparison.difference))")
                .font(.subheadline.monospacedDigit())
            Text(Format.interval(report.comparison.interval95) + String(format: " · design effect %.2f", report.designEffect))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var armsTable: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("By experiment arm (randomised, causal)").font(.caption.bold()).foregroundStyle(.secondary)
            ForEach([report.treatment, report.holdout], id: \.arm) { arm in
                HStack {
                    Text(arm.arm == .treatment ? "AI on" : "Holdout").frame(width: 70, alignment: .leading)
                    Text(Format.percent(arm.completion.rate)).frame(width: 64, alignment: .trailing)
                    Text("median \(Format.bound(arm.medianTimeToIntent))").frame(maxWidth: .infinity, alignment: .trailing)
                    Text("n=\(arm.completion.trials)").foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
                }
                .font(.footnote.monospacedDigit())
            }
        }
    }

    private var exposureTable: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("AI-on tasks by what the user did (descriptive only — confounded)")
                .font(.caption.bold()).foregroundStyle(.secondary)
            if report.exposures.isEmpty {
                Text("No exposure rows passed the privacy gate.").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(report.exposures, id: \.exposure) { row in
                HStack {
                    Text(Format.exposure(row.exposure)).frame(maxWidth: .infinity, alignment: .leading)
                    Text(Format.percent(row.completion.rate)).frame(width: 64, alignment: .trailing)
                    Text("n=\(row.completion.trials)").foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
                }
                .font(.footnote.monospacedDigit())
            }
            if let naive = naiveGap {
                Text("\"Used as offered\" vs. holdout: \(Format.points(naive)) — that gap is mostly *which* receipts get accepted, not the feature.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var naiveGap: Double? {
        guard let accepted = report.exposures.first(where: { $0.exposure == .accepted })?.completion.rate,
              let holdout = report.holdout.completion.rate else { return nil }
        return accepted - holdout
    }

    private var privacyNote: some View {
        Text("Privacy gate: \(report.coarsenedTreatmentTasks) AI-on tasks uploaded without their exposure; \(report.outcomeOnlyTasks) tasks reduced to outcome counts (in the rates, not the timings).")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

/// Where unfinished tasks stopped, by furthest funnel step.
public struct FunnelView: View {
    private let dropOff: [UInt64]
    private let noStepReached: UInt64

    public init(dropOff: [UInt64], noStepReached: UInt64) {
        self.dropOff = dropOff
        self.noStepReached = noStepReached
    }

    private var bars: [(label: String, count: UInt64)] {
        var result: [(String, UInt64)] = [("no step", noStepReached)]
        // Trailing zero steps are not shown; the array is fixed-size.
        let lastNonZero = dropOff.lastIndex { $0 > 0 } ?? -1
        if lastNonZero >= 0 {
            for index in 0 ... lastNonZero where dropOff.indices.contains(index) {
                result.append(("after step \(index + 1)", dropOff[index]))
            }
        }
        return result
    }

    public var body: some View {
        let rows = bars
        let peak = max(rows.map(\.count).max() ?? 0, 1)
        VStack(alignment: .leading, spacing: 4) {
            Text("Unfinished tasks: where they stopped").font(.caption.bold()).foregroundStyle(.secondary)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 6) {
                    Text(row.label).font(.caption2).frame(width: 74, alignment: .leading)
                    GeometryReader { proxy in
                        let fraction = CGFloat(Double(row.count) / Double(peak))
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.accentColor.opacity(0.7))
                            .frame(width: max(2, proxy.size.width * fraction))
                    }
                    .frame(height: 10)
                    Text("\(row.count)").font(.caption2.monospacedDigit()).frame(width: 40, alignment: .trailing)
                }
            }
        }
    }
}

/// One device's pipeline: where every finished task currently is.
public struct PipelineHealthView: View {
    private let health: PipelineHealth
    private let serverDuplicates: UInt64

    public init(health: PipelineHealth, serverDuplicates: UInt64) {
        self.health = health
        self.serverDuplicates = serverDuplicates
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: health.isConserved ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(health.isConserved ? .green : .red)
                Text(health.isConserved
                     ? "All \(health.finishedTasks) finished tasks accounted for"
                     : "Accounting mismatch: \(health.accountedTasks) of \(health.finishedTasks)")
                    .font(.subheadline.bold())
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                row("Open tasks", "\(health.openTasks)")
                row("Accumulating", "\(health.accumulatingTasks)")
                row("Carried (below k)", "\(health.carriedTasks)")
                row("Queued", "\(health.pendingTasks) in \(health.pendingBatches) batches (\(health.frozenBatches) frozen)")
                row("Coalesced seals", "\(health.coalescedSeals)")
                row("Acknowledged", "\(health.ackedTasks) in \(health.ackedBatches) batches")
                row("Dead-lettered", "\(health.deadLetteredTasks)")
                row("Duplicate sends deduped", "\(serverDuplicates)")
                row("Outcome-only (below k)", "\(health.outcomeOnlyTasks)")
                row("Rejected events", Self.describe(health.rejections))
            }
            .font(.footnote.monospacedDigit())
            if let last = health.lastFlush {
                Text("Last flush: \(Self.describe(last))").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
        }
    }

    static func describe(_ rejections: [Rejection: UInt64]) -> String {
        let parts = Rejection.allCases.compactMap { reason -> String? in
            guard let count = rejections[reason], count > 0 else { return nil }
            return "\(reason.rawValue) \(count)"
        }
        return parts.isEmpty ? "none" : parts.joined(separator: ", ")
    }

    static func describe(_ result: FlushResult) -> String {
        switch result {
        case .nothingToSend: return "nothing to send"
        case .alreadyFlushing: return "already flushing"
        case let .backingOff(remaining): return "backing off, \(remaining / 1_000_000_000) s left"
        case let .sent(_, tasks): return "sent \(tasks) tasks"
        case let .willRetry(_, attempt, delay): return "attempt \(attempt) failed, retry in \(delay / 1_000_000_000) s"
        case let .deadLettered(_, tasks): return "dead-lettered \(tasks) tasks"
        case .writeAheadFailed: return "write-ahead save failed; nothing sent"
        }
    }
}
#endif
