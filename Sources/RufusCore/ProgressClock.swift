import Foundation

/// Elapsed time and a remaining-time estimate for a running job.
///
/// The estimate comes from the *current phase's* own rate. The Windows path reports progress per
/// phase — "copying" runs 0…1, then "splitting" runs 0…1 again — so a single global estimate would
/// jump backwards at every phase boundary. Rates also differ wildly between phases, which would
/// make one carried across them wrong rather than merely coarse.
public struct ProgressClock {
    public init() {}

    private var startedAt: Date?
    private var finishedAt: Date?
    private var phase = ""
    private var phaseStartedAt = Date()
    private var phaseStartFraction: Double = 0
    private var fraction: Double = 0

    /// Below this much elapsed or progress within a phase, an extrapolation is noise.
    public static let minimumPhaseElapsed: TimeInterval = 3
    public static let minimumPhaseProgress: Double = 0.01

    public mutating func start(at now: Date = .now) {
        startedAt = now
        finishedAt = nil
        phase = ""
        phaseStartedAt = now
        phaseStartFraction = 0
        fraction = 0
    }

    /// Freeze the clock, keeping the total so it can be shown alongside "Done".
    public mutating func finish(at now: Date = .now) {
        guard startedAt != nil, finishedAt == nil else { return }
        finishedAt = now
    }

    public mutating func reset() { startedAt = nil; finishedAt = nil }

    public mutating func observe(phase newPhase: String, fraction newFraction: Double, at now: Date = .now) {
        guard startedAt != nil, finishedAt == nil else { return }
        if newPhase != phase {
            phase = newPhase
            phaseStartedAt = now
            phaseStartFraction = newFraction
        }
        fraction = newFraction
    }

    public func elapsed(at now: Date = .now) -> TimeInterval? {
        guard let startedAt else { return nil }
        return (finishedAt ?? now).timeIntervalSince(startedAt)
    }

    /// nil until the current phase has run long enough and far enough to extrapolate from.
    public func remaining(at now: Date = .now) -> TimeInterval? {
        guard startedAt != nil, finishedAt == nil, fraction < 1 else { return nil }
        let phaseElapsed = now.timeIntervalSince(phaseStartedAt)
        let progressed = fraction - phaseStartFraction
        guard phaseElapsed >= Self.minimumPhaseElapsed,
              progressed >= Self.minimumPhaseProgress else { return nil }
        return (1 - fraction) * (phaseElapsed / progressed)
    }

    /// "4:07", or "1:02:30" once past an hour.
    public static func format(_ interval: TimeInterval) -> String {
        let s = max(0, Int(interval.rounded()))
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}
