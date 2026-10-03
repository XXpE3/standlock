import Foundation
import StandLockCore
import Scheduling
import Detection
import Locking

/// Per-schedule counters that have to outlive a coordinator rebuild. Editing a schedule tears
/// the coordinator down and builds a new one, and every counter here lives on the instance: a
/// fresh one re-arms `dailyBreakCap` from zero, sends `intervalCycle` back to its first entry,
/// drops progressive enforcement to the base tier and forgets how far into the short-break run
/// the user was. A day change still clears all of it, in `rolloverIfNeeded`.
public struct EnforcementState: Sendable {
    public var dailyBreakCounts: [UUID: Int]
    public var escalationTiers: [UUID: Int]
    public var cycleIndices: [UUID: Int]
    public var repetitionIndices: [UUID: Int]
    /// The slot the outgoing coordinator had armed, with the schedule it belongs to. The
    /// interval is measured from whenever the rebuilt coordinator starts, so without this any
    /// restart -- a schedule edit, a Strict permission reading that flaps -- pushes the break
    /// out by however far into the interval the user already was. The id travels with the date
    /// because the slot decides which schedule's break fires, not only when.
    public var pendingBreakScheduleID: UUID?
    public var pendingBreakDate: Date?
    /// A grace wait owed across a coordinator rebuild. The slot was already offered once, so the
    /// restored break must come back through the due-checks with no second postpone.
    public var graceScheduleID: UUID?
    public var graceRetryDate: Date?

    public init(dailyBreakCounts: [UUID: Int] = [:], escalationTiers: [UUID: Int] = [:],
                cycleIndices: [UUID: Int] = [:], repetitionIndices: [UUID: Int] = [:],
                pendingBreakScheduleID: UUID? = nil, pendingBreakDate: Date? = nil,
                graceScheduleID: UUID? = nil, graceRetryDate: Date? = nil) {
        self.dailyBreakCounts = dailyBreakCounts
        self.escalationTiers = escalationTiers
        self.cycleIndices = cycleIndices
        self.repetitionIndices = repetitionIndices
        self.pendingBreakScheduleID = pendingBreakScheduleID
        self.pendingBreakDate = pendingBreakDate
        self.graceScheduleID = graceScheduleID
        self.graceRetryDate = graceRetryDate
    }
}

/// A skip the menu can take back. An overlay skip has already consumed its slot and may have
/// raised the progressive tier; a menu skip has only moved the cycle index forward.
private struct ReversibleSkip {
    let at: Date
    let scheduleID: UUID
    let previousStreak: Int
    let slotAlreadyCommitted: Bool
    let escalated: Bool
}

@MainActor
public final class BreakCoordinator {
    private let scheduler: any SchedulingEngine
    private let detector: any ContextDetecting
    private let locker: any LockPresenting

    private var activeSchedules: [Schedule] = []
    private var preferences: AppPreferences = AppPreferences()
    private var repetitionTrackers: [UUID: RepetitionTracker] = [:]
    private var breakTimer: Task<Void, Never>?
    private var isPaused: Bool = false
    /// Set while the screen is locked or the machine is asleep. Distinct from `isPaused`, which
    /// is the user-facing pause; suspension only blocks work being started behind a dark screen.
    private var isSuspended: Bool = false
    private var currentBreak: BreakEvent?
    private var currentSchedule: Schedule?
    private var statistics: BreakStatistics = BreakStatistics()
    private var dailyBreakCounts: [UUID: Int] = [:]
    private var escalationTiers: [UUID: Int] = [:]
    private var cycleIndices: [UUID: Int] = [:]
    /// Which schedule the armed break timer targets. A menu skip of a not-yet-fired break has
    /// to advance that schedule's cycle; cleared whenever the timer is cancelled or the break
    /// becomes active, so a slot can never advance twice.
    private var pendingBreakScheduleID: UUID?
    /// When the pending slot is due. Kept so a skip that is not allowed to reset the interval
    /// can measure the next one from the slot it skipped instead of from the moment of the skip.
    private var pendingBreakDate: Date?
    /// True only while the deferral poll loop owns `breakTimer`. That loop is suspended between
    /// polls, so anything that re-arms the timer cancels it and drops the deferred break.
    private var isDeferringBreak = false
    /// A slot carried in from the coordinator this one replaces, consumed by the first
    /// `scheduleNextBreak` after `start`. Kept apart from `pendingBreakDate` so it can re-arm
    /// once and only once: a slot left in play would pin every later break to the same date.
    private var restoredPendingBreak: (scheduleID: UUID, date: Date)?
    /// Grace owed by the coordinator this one replaces. Consumed once, like `restoredPendingBreak`.
    private var restoredGrace: (scheduleID: UUID, date: Date)?
    /// True after this slot's one postpone has been used. The return showing offers no second one.
    private var graceUsedForCurrentSlot = false
    /// Deadline of the opening postpone control for the overlay that is up now.
    private var graceOfferDeadline: Date?
    /// True while the postpone timer owns `breakTimer` and the break has been rolled back to waiting.
    private var isInGraceWait = false
    /// Schedule whose grace was interrupted by a pause. Resume asks for that break again.
    private var graceOwedScheduleID: UUID?
    /// A not-yet-due slot parked across sleep or system lock. Cleared when the suspension ends.
    private var heldSlot: (scheduleID: UUID, date: Date)?
    /// The latest skip, kept so a break started from the menu can take it back. One is enough:
    /// a newer skip replaces it, and showing any overlay spends it.
    private var reversibleSkip: ReversibleSkip?
    public var exercises: [Exercise] = []

    /// Floor between a skip and the break it schedules, for the case where the anchored slot
    /// has already gone by.
    private static let minimumLeadTime: TimeInterval = 60
    /// How long a skip can be taken back by starting a break from the menu. Long enough to
    /// catch a click that was still meant for the work underneath a lock that just appeared.
    private static let skipReversalWindow: TimeInterval = 60
    /// The grace before a postponed break returns. The overlay's postpone button label reads
    /// this, so the advertised countdown and the actual timer can never drift apart.
    public static let defaultPostponeInterval: TimeInterval = 30
    /// How long the postpone control stays available after a lock first appears. Past this the
    /// lock is formal: the opening seconds already count toward the break, and postpone is refused.
    public static let defaultGraceOfferWindow: TimeInterval = 10

    private let deferralPollingInterval: TimeInterval
    private let graceOfferWindow: TimeInterval
    private let eventContinuation: AsyncStream<CoordinatorEvent>.Continuation
    public nonisolated let events: AsyncStream<CoordinatorEvent>

    public init(scheduler: any SchedulingEngine, detector: any ContextDetecting,
                locker: any LockPresenting, deferralPollingInterval: TimeInterval = 10,
                graceOfferWindow: TimeInterval = BreakCoordinator.defaultGraceOfferWindow) {
        var continuation: AsyncStream<CoordinatorEvent>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.eventContinuation = continuation
        self.scheduler = scheduler
        self.detector = detector
        self.locker = locker
        self.deferralPollingInterval = deferralPollingInterval
        self.graceOfferWindow = graceOfferWindow
    }

    /// Pass previously persisted `statistics` so a relaunch during the day keeps today's
    /// counters instead of restarting them from zero.
    public func start(with schedules: [Schedule], preferences: AppPreferences,
                      statistics: BreakStatistics = BreakStatistics(),
                      restoring state: EnforcementState = EnforcementState()) {
        self.activeSchedules = schedules
        self.preferences = preferences
        self.statistics = statistics
        dailyBreakCounts = state.dailyBreakCounts
        escalationTiers = state.escalationTiers
        cycleIndices = state.cycleIndices
        for schedule in schedules {
            if let rule = schedule.repetitionRule {
                repetitionTrackers[schedule.id] = RepetitionTracker(
                    rule: rule, currentBreakIndex: state.repetitionIndices[schedule.id] ?? 0
                )
            }
        }
        if let id = state.pendingBreakScheduleID, let date = state.pendingBreakDate {
            restoredPendingBreak = (id, date)
        }
        if let id = state.graceScheduleID, let date = state.graceRetryDate {
            restoredGrace = (id, date)
        }
        scheduleNextBreak()
    }

    /// Read this before `stop()`, which clears `escalationTiers` on its way out.
    public func captureEnforcementState() -> EnforcementState {
        EnforcementState(
            dailyBreakCounts: dailyBreakCounts,
            escalationTiers: escalationTiers,
            cycleIndices: cycleIndices,
            repetitionIndices: repetitionTrackers.mapValues(\.currentBreakIndex),
            pendingBreakScheduleID: isInGraceWait ? nil : pendingBreakScheduleID,
            pendingBreakDate: isInGraceWait ? nil : pendingBreakDate,
            graceScheduleID: isInGraceWait ? pendingBreakScheduleID : nil,
            graceRetryDate: isInGraceWait ? pendingBreakDate : nil
        )
    }

    public func stop() {
        breakTimer?.cancel()
        breakTimer = nil
        clearPendingBreak()
        if locker.isShowing { locker.dismissOverlay() }
        currentBreak = nil
        currentSchedule = nil
        isInGraceWait = false
        graceUsedForCurrentSlot = false
        graceOfferDeadline = nil
        graceOwedScheduleID = nil
        restoredGrace = nil
        heldSlot = nil
        reversibleSkip = nil
        escalationTiers.removeAll()
    }

    public func pause(for duration: TimeInterval) {
        let owedGraceID = isInGraceWait ? pendingBreakScheduleID : nil
        breakTimer?.cancel()
        breakTimer = nil
        clearPendingBreak()
        isPaused = true
        graceOwedScheduleID = owedGraceID
        // Grace has already been rolled back to a waiting break, so pausing must not settle it
        // as taken. The resume below asks for that same break again. An overlay that is still
        // up stays up; only a half-open break with nothing on screen is closed here.
        if owedGraceID == nil, !locker.isShowing, let event = currentBreak, let schedule = currentSchedule {
            completeBreak(event: event, schedule: schedule)
        }
        let until = Date().addingTimeInterval(duration)
        eventContinuation.yield(.schedulePaused(until: until))
        breakTimer = Task {
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            resume()
        }
    }

    public func resume() {
        // The pause task lives in `breakTimer`. An early resume has to cancel it, or the
        // original deadline later calls `resume` again and arms a slot behind the break
        // this call just asked for.
        breakTimer?.cancel()
        breakTimer = nil
        isPaused = false
        eventContinuation.yield(.scheduleResumed)
        if let id = graceOwedScheduleID {
            graceOwedScheduleID = nil
            if let schedule = activeSchedules.first(where: { $0.id == id && $0.isEnabled }) {
                // Due now, but still a grace wait until the context check returns. Sleep or
                // lock in that gap has to see `isInGraceWait` and count the break taken,
                // and a second pause has to be able to owe it again.
                beginGraceWait(for: schedule, until: Date())
                return
            }
        }
        scheduleNextBreak()
    }

    /// Rolls the daily counters over when the calendar day has changed. Safe to call often --
    /// it is a no-op while the recorded day is still the current one.
    public func refreshDailyRollover(now: Date = Date()) {
        guard rolloverIfNeeded(now: now) else { return }
        // Re-arm on every rollover: a schedule that exhausted its daily cap left no timer
        // behind, and a timer armed before midnight was computed from the old day's cycle
        // index -- the new day's first break must come from index 0 (scheduleNextBreak
        // cancels any pending timer itself). Nothing may be armed behind a locked or
        // sleeping screen, while paused the timer holds the resume task, and re-arming
        // during a deferral would cancel the poll loop and lose the deferred break.
        if !isPaused && !isSuspended && !isDeferringBreak && !isInGraceWait {
            scheduleNextBreak(now: now)
        }
    }

    @discardableResult
    private func rolloverIfNeeded(now: Date = Date()) -> Bool {
        guard statistics.resetDailyIfNeeded(currentDate: now) else { return false }
        statistics.resetWeeklyIfNeeded(currentDate: now)
        dailyBreakCounts.removeAll()
        // Progressive enforcement escalates within a day; a new day starts from the base tier.
        escalationTiers.removeAll()
        // Every day starts the interval cycle from its first entry.
        cycleIndices.removeAll()
        eventContinuation.yield(.statisticsUpdated(statistics))
        return true
    }

    private func updateStatistics(_ mutate: (inout BreakStatistics) -> Void) {
        rolloverIfNeeded()
        mutate(&statistics)
        eventContinuation.yield(.statisticsUpdated(statistics))
    }

    public func handleSystemSleep() {
        beginSuspension()
    }

    public func handleSystemWake() {
        endSuspension()
    }

    public func handleScreenLock() {
        beginSuspension()
    }

    public func handleScreenUnlock() {
        endSuspension()
    }

    /// Sleep and system lock can both arrive for one absence. The first call records when it
    /// began and parks a future slot; the matching wake or unlock settles that slot once.
    private func beginSuspension() {
        isSuspended = true
        if heldSlot == nil, !isInGraceWait, !isDeferringBreak,
           let id = pendingBreakScheduleID, let date = pendingBreakDate {
            heldSlot = (id, date)
        }
        settleAbsence()
    }

    private func endSuspension() {
        guard isSuspended else { return }
        let slot = heldSlot
        heldSlot = nil
        isSuspended = false
        if isPaused {
            resume()
            return
        }
        if let slot {
            settleHeldSlot(slot)
        } else {
            scheduleNextBreak()
        }
    }

    /// The user is gone. A break already on screen, in its opening grace, or waiting on a sensor
    /// counts as taken. A future slot is left in `heldSlot` for the wake to judge.
    private func settleAbsence() {
        breakTimer?.cancel()
        breakTimer = nil
        if let event = currentBreak, let schedule = currentSchedule {
            pendingBreakScheduleID = nil
            pendingBreakDate = nil
            isDeferringBreak = false
            isInGraceWait = false
            completeBreak(event: event, schedule: schedule)
            return
        }
        if isInGraceWait || isDeferringBreak, let id = pendingBreakScheduleID,
           let schedule = activeSchedules.first(where: { $0.id == id }) {
            isInGraceWait = false
            isDeferringBreak = false
            pendingBreakScheduleID = nil
            pendingBreakDate = nil
            currentBreak = nil
            currentSchedule = nil
            recordAbsence(for: schedule, at: Date())
            return
        }
        pendingBreakScheduleID = nil
        pendingBreakDate = nil
        isDeferringBreak = false
        isInGraceWait = false
        currentBreak = nil
        currentSchedule = nil
    }

    /// A slot that was only armed, not showing, when the machine went away.
    /// Still in the future: keep it. Time since it came due covers a full break: count it taken.
    /// It came due, but the missed slice is shorter than the break: ask now.
    /// Time asleep before the slot is not part of the break. A nap that merely overlaps
    /// the fire time must not be recorded as a completed break.
    private func settleHeldSlot(_ slot: (scheduleID: UUID, date: Date)) {
        guard let schedule = activeSchedules.first(where: {
            $0.id == slot.scheduleID && $0.isEnabled
        }), !isCapReached(schedule) else {
            scheduleNextBreak()
            return
        }
        if slot.date > Date() {
            restoredPendingBreak = (slot.scheduleID, slot.date)
            scheduleNextBreak()
            return
        }
        let sinceFire = Date().timeIntervalSince(slot.date)
        if sinceFire >= currentBreakDuration(for: schedule) {
            recordAbsence(for: schedule, at: slot.date)
            return
        }
        Task {
            let context = await self.detector.currentContext()
            await self.triggerBreak(for: schedule, context: context)
        }
    }

    /// Counts a due break the user never refused: they were away. Not a skip.
    private func recordAbsence(for schedule: Schedule, at date: Date) {
        commitSlot(schedule)
        let duration = currentBreakDuration(for: schedule)
        let event = BreakEvent(
            scheduledAt: date, duration: duration,
            level: schedule.disciplineLevel, scheduleId: schedule.id
        )
        completeBreak(event: event, schedule: schedule)
    }

    public func skipNextBreak() {
        breakTimer?.cancel()
        breakTimer = nil
        if let id = pendingBreakScheduleID {
            cycleIndices[id, default: 0] += 1
            // Recorded before the streak is zeroed, and this skip has not consumed a daily slot.
            noteReversibleSkip(scheduleID: id, slotAlreadyCommitted: false, escalated: false)
        }
        let anchor = skipAnchor(slot: pendingBreakDate)
        clearPendingBreak()
        updateStatistics {
            $0.breaksSkipped += 1
            $0.currentStreak = 0
        }
        scheduleNextBreak(searchFrom: anchor)
    }

    public func skipActiveBreak() {
        guard let event = currentBreak else { return }
        let scheduleID = event.scheduleId
        let maxTier = (currentSchedule?.disciplineLevel.enforcementPolicy(preferences: preferences).tiers.count ?? 5) - 1
        let previousTier = escalationTiers[scheduleID, default: 0]
        let raisedTier = min(previousTier + 1, maxTier)
        escalationTiers[scheduleID] = raisedTier
        // The overlay already ran `commitSlot`. Taking the skip back must not consume another.
        noteReversibleSkip(
            scheduleID: scheduleID,
            slotAlreadyCommitted: true,
            escalated: raisedTier > previousTier
        )
        locker.dismissOverlay()
        eventContinuation.yield(.breakSkipped(event))
        updateStatistics {
            $0.breaksSkipped += 1
            $0.currentStreak = 0
        }
        let anchor = skipAnchor(slot: event.scheduledAt)
        currentBreak = nil
        currentSchedule = nil
        scheduleNextBreak(searchFrom: anchor)
    }

    /// Opens a break immediately, in place of whatever slot was armed. A skip from the last
    /// minute is taken back first: the skip counter and streak return to where they were, and
    /// the slot that skip already consumed is not consumed again.
    public func startBreakNow(now: Date = Date()) {
        guard !isPaused, !isSuspended else { return }
        guard currentBreak == nil, !locker.isShowing else { return }

        if let skip = reversibleSkip,
           now.timeIntervalSince(skip.at) <= Self.skipReversalWindow,
           let schedule = activeSchedules.first(where: { $0.id == skip.scheduleID && $0.isEnabled }) {
            reversibleSkip = nil
            reverseSkip(skip)
            disarmArmedBreak()
            presentBreak(for: schedule, level: schedule.disciplineLevel, commitsSlot: !skip.slotAlreadyCommitted)
            return
        }

        guard let schedule = scheduleForImmediateBreak() else { return }
        disarmArmedBreak()
        presentBreak(for: schedule, level: schedule.disciplineLevel, commitsSlot: true)
    }

    public func escapeActiveBreak() {
        guard let event = currentBreak else { return }
        if let scheduleID = currentBreak?.scheduleId {
            let maxTier = (currentSchedule?.disciplineLevel.enforcementPolicy(preferences: preferences).tiers.count ?? 5) - 1
            escalationTiers[scheduleID, default: 0] = min(escalationTiers[scheduleID, default: 0] + 1, maxTier)
        }
        locker.dismissOverlay()
        eventContinuation.yield(.breakEscaped(event))
        updateStatistics {
            $0.breaksEscaped += 1
            $0.weeklyEscapeCount += 1
        }
        currentBreak = nil
        currentSchedule = nil
        scheduleNextBreak()
    }

    /// Rolls the showing break back into a short wait. The slot spent when the overlay appeared
    /// is returned, nothing is recorded, and the break comes due again through the normal checks:
    /// already-away completes it, a sensor defers it, otherwise the lock returns with no second
    /// postpone. Refused once the opening window has passed, after grace was already used, for
    /// strict, and while paused or suspended.
    public func postponeActiveBreak(by interval: TimeInterval = BreakCoordinator.defaultPostponeInterval) {
        guard !isPaused, !isSuspended else { return }
        guard !graceUsedForCurrentSlot else { return }
        guard let deadline = graceOfferDeadline, Date() <= deadline else { return }
        guard let schedule = currentSchedule, currentBreak != nil else { return }

        graceUsedForCurrentSlot = true
        graceOfferDeadline = nil
        rollbackSlot(schedule)
        locker.dismissOverlay()
        currentBreak = nil
        currentSchedule = nil
        beginGraceWait(for: schedule, until: Date().addingTimeInterval(max(0, interval)))
    }

    /// Parks this slot until `date`, then runs it through `triggerBreak` again. One postpone per
    /// slot: `graceUsedForCurrentSlot` stays set so the return showing has no postpone control.
    /// `isInGraceWait` stays set across the context check. Clearing it before that await lets
    /// sleep or lock land in the gap and drop the break: the absence settler no longer sees a
    /// grace wait, and this task no longer has a slot to bring back.
    private func beginGraceWait(for schedule: Schedule, until date: Date) {
        graceUsedForCurrentSlot = true
        isInGraceWait = true
        pendingBreakScheduleID = schedule.id
        pendingBreakDate = date
        isDeferringBreak = false
        let delay = max(0, date.timeIntervalSinceNow)
        // A wait of zero is an immediate retry (resume, or a restored deadline already past).
        // Announcing it would flash a grace row for a break that is about to open.
        if delay > 0 {
            eventContinuation.yield(.breakGrace(until: date))
        }
        breakTimer?.cancel()
        breakTimer = Task {
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard !Task.isCancelled else { return }
            guard self.isInGraceWait else { return }
            let context = await self.detector.currentContext()
            guard !Task.isCancelled else { return }
            guard self.isInGraceWait else { return }
            self.isInGraceWait = false
            self.pendingBreakScheduleID = nil
            self.pendingBreakDate = nil
            await self.triggerBreak(for: schedule, context: context)
        }
    }

    public func completeActiveBreak() {
        guard let event = currentBreak, let schedule = currentSchedule else { return }
        completeBreak(event: event, schedule: schedule)
    }

    public func changeDisciplineLevel(_ level: DisciplineLevel) {
        for i in activeSchedules.indices {
            activeSchedules[i].disciplineLevel = level
        }
    }

    public func updatePreferences(_ preferences: AppPreferences) {
        self.preferences = preferences
    }

    // MARK: - Escalation

    /// Nil keeps the default `now` anchor. A slot date is returned only when the user has turned
    /// off `resetIntervalOnSkip`, which is what makes a skip cost the time it saved.
    private func skipAnchor(slot: Date?) -> Date? {
        preferences.resetIntervalOnSkip ? nil : slot
    }

    private func currentTier(for schedule: Schedule) -> Int {
        guard schedule.progressiveEnforcement else { return 0 }
        let maxTier = schedule.disciplineLevel.enforcementPolicy(preferences: preferences).tiers.count - 1
        return min(escalationTiers[schedule.id, default: 0], maxTier)
    }

    // MARK: - Private

    /// The pending slot and the deferral flag always end together: whoever concludes a slot
    /// concludes the poll that was waiting on it.
    private func clearPendingBreak() {
        pendingBreakScheduleID = nil
        pendingBreakDate = nil
        isDeferringBreak = false
        isInGraceWait = false
    }

    /// Drops a countdown, a deferral poll, or a grace wait without recording how it ended.
    /// `graceUsedForCurrentSlot` is left as it is: a postpone already spent stays spent.
    private func disarmArmedBreak() {
        breakTimer?.cancel()
        breakTimer = nil
        clearPendingBreak()
        graceOwedScheduleID = nil
        restoredGrace = nil
        heldSlot = nil
    }

    /// The schedule whose break is counting down, or the first enabled one when nothing is armed.
    private func scheduleForImmediateBreak() -> Schedule? {
        if let id = pendingBreakScheduleID,
           let schedule = activeSchedules.first(where: { $0.id == id && $0.isEnabled }) {
            return schedule
        }
        return activeSchedules.first(where: \.isEnabled)
    }

    /// Captured before the skip zeroes the streak. `slotAlreadyCommitted` distinguishes an
    /// overlay skip, which already counted the slot, from a menu skip, which only advanced
    /// the cycle index.
    private func noteReversibleSkip(scheduleID: UUID, slotAlreadyCommitted: Bool, escalated: Bool) {
        reversibleSkip = ReversibleSkip(
            at: Date(),
            scheduleID: scheduleID,
            previousStreak: statistics.currentStreak,
            slotAlreadyCommitted: slotAlreadyCommitted,
            escalated: escalated
        )
    }

    private func reverseSkip(_ skip: ReversibleSkip) {
        if skip.escalated {
            let tier = escalationTiers[skip.scheduleID, default: 0]
            if tier > 0 {
                escalationTiers[skip.scheduleID] = tier - 1
            }
        }
        if !skip.slotAlreadyCommitted {
            let index = cycleIndices[skip.scheduleID, default: 0]
            if index > 0 {
                cycleIndices[skip.scheduleID] = index - 1
            }
        }
        updateStatistics { stats in
            if stats.breaksSkipped > 0 {
                stats.breaksSkipped -= 1
            }
            stats.currentStreak = skip.previousStreak
        }
    }

    private func commitSlot(_ schedule: Schedule) {
        dailyBreakCounts[schedule.id, default: 0] += 1
        cycleIndices[schedule.id, default: 0] += 1
    }

    private func rollbackSlot(_ schedule: Schedule) {
        let count = dailyBreakCounts[schedule.id, default: 0]
        if count > 0 {
            dailyBreakCounts[schedule.id] = count - 1
        }
        let index = cycleIndices[schedule.id, default: 0]
        if index > 0 {
            cycleIndices[schedule.id] = index - 1
        }
    }

    private func isCapReached(_ schedule: Schedule) -> Bool {
        guard let cap = schedule.dailyBreakCap else { return false }
        return (dailyBreakCounts[schedule.id] ?? 0) >= cap
    }

    /// `now` governs both the rollover check and the search for the next break, so an injected
    /// date describes one consistent moment. Without it the rollover here would re-read the real
    /// clock and undo a caller-injected day change, since `resetDailyIfNeeded` fires in both
    /// directions.
    /// `searchFrom` is the moment the next interval is measured from. It differs from `now` only
    /// when `resetIntervalOnSkip` is off, where the skipped slot stays the anchor so a skip
    /// neither buys work time nor pulls the next break closer.
    private func scheduleNextBreak(now: Date = Date(), searchFrom: Date? = nil) {
        breakTimer?.cancel()
        breakTimer = nil
        rolloverIfNeeded(now: now)
        guard !isPaused else { return }
        guard !isSuspended else { return }

        if let grace = restoredGrace {
            restoredGrace = nil
            if let schedule = activeSchedules.first(where: {
                $0.id == grace.scheduleID && $0.isEnabled
            }) {
                beginGraceWait(for: schedule, until: grace.date)
                return
            }
        }

        graceUsedForCurrentSlot = false
        graceOfferDeadline = nil

        var earliest: (date: Date, schedule: Schedule)?
        // The carried slot competes with the freshly computed ones instead of overriding them,
        // so a schedule whose interval the user just shortened still wins with its earlier date.
        // A slot already in the past is dropped: it belongs to a gap the coordinator sat out --
        // every schedule disabled, then re-enabled -- and re-arming it would fire on the spot.
        if let restored = restoredPendingBreak {
            restoredPendingBreak = nil
            if restored.date > now,
               let schedule = activeSchedules.first(where: {
                   $0.id == restored.scheduleID && $0.isEnabled
               }), !isCapReached(schedule) {
                earliest = (restored.date, schedule)
            }
        }
        for schedule in activeSchedules where schedule.isEnabled {
            if isCapReached(schedule) { continue }
            if let next = scheduler.nextBreakTime(for: schedule, after: searchFrom ?? now,
                                                  cycleIndex: cycleIndices[schedule.id, default: 0]) {
                if earliest == nil || next < earliest!.date {
                    earliest = (next, schedule)
                }
            }
        }

        guard let target = earliest else { return }
        // An anchored slot can already have gone by; a break must never open right on top of the
        // skip that scheduled it. The unanchored path keeps its exact slot, short ones included.
        let fireDate = searchFrom == nil
            ? target.date
            : max(target.date, now.addingTimeInterval(Self.minimumLeadTime))
        pendingBreakScheduleID = target.schedule.id
        pendingBreakDate = fireDate
        eventContinuation.yield(.nextBreakScheduled(fireDate))

        breakTimer = Task {
            let delay = fireDate.timeIntervalSince(Date())
            let leadTime: TimeInterval = 3
            let earlyDelay = max(0, delay - leadTime)
            if earlyDelay > 0 { try? await Task.sleep(for: .seconds(earlyDelay)) }
            guard !Task.isCancelled else { return }
            let context = await self.detector.currentContext()
            let remaining = fireDate.timeIntervalSince(Date())
            if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
            guard !Task.isCancelled else { return }
            await self.triggerBreak(for: target.schedule, context: context)
        }
    }

    private func triggerBreak(for schedule: Schedule, context: DetectionContext) async {
        // A menu break may already be on screen. This call belongs to a timer that lost the
        // race; continuing would open a second overlay or record the slot twice.
        guard currentBreak == nil, !locker.isShowing else { return }
        // The pending break is now active; a menu skip from here on must not advance again.
        clearPendingBreak()
        rolloverIfNeeded()
        if preferences.idleDetectionEnabled {
            let breakDuration = currentBreakDuration(for: schedule)
            // A break under a minute must not be swallowed by a glance away from the keyboard:
            // idle counts as a break only once it reaches a minute, or the full break when longer.
            if context.idleDuration >= max(breakDuration, 60) {
                let idleEvent = BreakEvent(
                    scheduledAt: Date(), duration: breakDuration,
                    level: schedule.disciplineLevel, scheduleId: schedule.id
                )
                if var tracker = repetitionTrackers[schedule.id] {
                    tracker.recordBreak()
                    repetitionTrackers[schedule.id] = tracker
                }
                dailyBreakCounts[schedule.id, default: 0] += 1
                cycleIndices[schedule.id, default: 0] += 1
                escalationTiers[schedule.id] = 0
                eventContinuation.yield(.breakCompleted(idleEvent))
                updateStatistics {
                    $0.breaksCompleted += 1
                    $0.currentStreak += 1
                }
                scheduleNextBreak()
                return
            }
        }

        if let deferral = shouldDefer(context: context) {
            // The deferred slot is still pending, so a menu skip during the poll loop
            // must conclude it for this schedule.
            pendingBreakScheduleID = schedule.id
            pendingBreakDate = Date()
            isDeferringBreak = true
            eventContinuation.yield(.breakDeferred(deferral, nextAttempt: Date().addingTimeInterval(deferralPollingInterval)))
            updateStatistics { $0.breaksDeferred += 1 }
            breakTimer = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(self.deferralPollingInterval))
                    guard !Task.isCancelled else { return }
                    let freshContext = await self.detector.currentContext()
                    // Cancellation does not interrupt the await above, so re-check before
                    // mutating: a menu skip during it already concluded this slot.
                    guard !Task.isCancelled else { return }
                    if let newReason = self.shouldDefer(context: freshContext) {
                        self.eventContinuation.yield(.breakDeferred(newReason, nextAttempt: Date().addingTimeInterval(self.deferralPollingInterval)))
                    } else if self.shouldSkipAfterDeferral(reason: deferral) {
                        self.cycleIndices[schedule.id, default: 0] += 1
                        self.clearPendingBreak()
                        self.scheduleNextBreak()
                        return
                    } else {
                        await self.triggerBreak(for: schedule, context: freshContext)
                        return
                    }
                }
            }
            return
        }

        var effectiveLevel = schedule.disciplineLevel
        if let reduction = shouldReduce(context: context) {
            effectiveLevel = reduction
        }
        presentBreak(for: schedule, level: effectiveLevel, commitsSlot: true)
    }

    /// Puts the overlay up and starts its countdown. Detection has already had its say for a
    /// scheduled break; a break the user asked for passes the schedule's own level and does
    /// not wait on idle or a deferrable context. `commitsSlot` is false only when taking back
    /// an overlay skip, whose slot was counted the first time the lock appeared.
    private func presentBreak(for schedule: Schedule, level: DisciplineLevel, commitsSlot: Bool) {
        reversibleSkip = nil
        let duration = currentBreakDuration(for: schedule)
        let exercise = exercises.randomElement()
        let tier = currentTier(for: schedule)
        let breakEvent = BreakEvent(
            scheduledAt: Date(), duration: duration,
            level: level, scheduleId: schedule.id
        )
        currentBreak = breakEvent
        currentSchedule = schedule
        if commitsSlot {
            commitSlot(schedule)
        }

        let deadline = graceDeadline(for: level)
        graceOfferDeadline = deadline
        eventContinuation.yield(.breakStarted(breakEvent))
        locker.showOverlay(level: level, duration: duration,
                           exercise: exercise, preferences: preferences,
                           statistics: statistics, escalationTier: tier,
                           nextIntervalLabel: nextIntervalLabel(for: schedule),
                           graceOfferDeadline: deadline)
    }

    /// One postpone, and only while this appearance is still in its opening window. Strict never
    /// offers it: the event tap would swallow the click anyway.
    private func graceDeadline(for level: DisciplineLevel) -> Date? {
        guard !graceUsedForCurrentSlot, level != .strict else { return nil }
        return Date().addingTimeInterval(graceOfferWindow)
    }

    /// The cycle index was already advanced when this break triggered, so it points at the
    /// upcoming work block.
    private func nextIntervalLabel(for schedule: Schedule) -> String? {
        guard let cycle = schedule.intervalCycle, !cycle.isEmpty else { return nil }
        return cycle[cycleIndices[schedule.id, default: 0] % cycle.count].label
    }

    private func currentBreakDuration(for schedule: Schedule) -> TimeInterval {
        if let tracker = repetitionTrackers[schedule.id] {
            return tracker.currentDuration
        }
        return schedule.breakDuration
    }

    private func shouldDefer(context: DetectionContext) -> DeferralReason? {
        if context.cameraActive && preferences.cameraDetection == .deferBreak { return .cameraActive }
        if context.microphoneActive && preferences.microphoneDetection == .deferBreak { return .microphoneActive }
        if context.calendarEventActive && preferences.calendarDetectionEnabled { return .calendarEvent }
        if context.screenSharingActive && preferences.screenSharingDetectionEnabled { return .screenSharing }
        return nil
    }

    private func shouldSkipAfterDeferral(reason: DeferralReason) -> Bool {
        reason == .screenSharing && preferences.screenSharingPostDeferral == .skipBreak
    }

    private func shouldReduce(context: DetectionContext) -> DisciplineLevel? {
        if context.cameraActive && preferences.cameraDetection == .reduceToGentle { return .gentle }
        if context.microphoneActive && preferences.microphoneDetection == .reduceToGentle { return .gentle }
        return nil
    }

    private func completeBreak(event: BreakEvent, schedule: Schedule) {
        escalationTiers[schedule.id] = 0
        locker.dismissOverlay()
        if var tracker = repetitionTrackers[schedule.id] {
            tracker.recordBreak()
            repetitionTrackers[schedule.id] = tracker
        }
        eventContinuation.yield(.breakCompleted(event))
        updateStatistics {
            $0.breaksCompleted += 1
            $0.currentStreak += 1
        }
        currentBreak = nil
        currentSchedule = nil
        scheduleNextBreak()
    }
}
