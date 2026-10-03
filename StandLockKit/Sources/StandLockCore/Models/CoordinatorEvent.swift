import Foundation

public enum CoordinatorEvent: Sendable {
    case nextBreakScheduled(Date)
    case breakStarted(BreakEvent)
    case breakCompleted(BreakEvent)
    case breakSkipped(BreakEvent)
    case breakEscaped(BreakEvent)
    case breakDeferred(DeferralReason, nextAttempt: Date)
    /// The overlay stepped aside for a short grace. The break is not in progress and has not
    /// been skipped; it returns through the normal due-checks at `until`.
    case breakGrace(until: Date)
    case schedulePaused(until: Date)
    case scheduleResumed
    case statisticsUpdated(BreakStatistics)
}
