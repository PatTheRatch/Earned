import Foundation

/// One system permission dialog at a time.
///
/// iOS presents Health, notification and Screen Time prompts on the same
/// window, and asking for two at once does not queue them — the second is
/// presented over the first. Earned managed exactly that on the most important
/// tap in the product: **COMMIT** on a first commitment fired
/// `health.requestAccess()` directly, while the ledger append it performed
/// caused warnings to be rescheduled, which asked for notification permission a
/// few milliseconds later. The result was Apple's full-screen Health sheet with
/// the notifications alert stacked on top of it and Earned's own UI nowhere in
/// sight, which is indistinguishable from the app having frozen — and was
/// reported as exactly that.
///
/// Each subsystem already guarded against repeating *its own* prompt. Nothing
/// coordinated them with each other, because nothing owned the question.
///
/// This does. Every call that can put a system dialog on screen goes through
/// here and waits for whatever is already showing. It is deliberately a chain
/// rather than a lock: a prompt that is never answered must not deadlock the
/// next one, and awaiting a `Task` that has finished is free.
@MainActor
enum SystemPrompts {

    /// The most recently enqueued prompt. `@MainActor` isolation is what makes
    /// read-modify-write of this safe without a lock.
    private static var tail: Task<Void, Never>?

    /// Run `work` once every prompt enqueued before it has finished.
    ///
    /// Order is first-come, and the caller's own `await` resumes only after its
    /// prompt has been answered — so a caller can still react to the result
    /// exactly as it did when it asked directly.
    static func serialized(_ work: @escaping @MainActor () async -> Void) async {
        let previous = tail
        let task = Task { @MainActor in
            // A cancelled or failed predecessor must not strand the queue: the
            // value of a finished Task is available immediately either way.
            await previous?.value
            await work()
        }
        tail = task
        await task.value
    }
}
