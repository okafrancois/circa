// Injected into a scratch copy of the original coordinator test's main by the review runner.
// The original file and every prior assertion remain unchanged in Git.
do {
    let native = NativeDouble(); native.mode = .delayed
    var coordinator: ChromiumAuthenticationImport? = native.make()
    let target = coordinator!.createFreshSyntheticTarget(for: ProfileID(), persistSession: false)!
    let handle = coordinator!.submit(target, consuming: [try prepared()])
    var updates = 0
    handle.onChange = { _, drained in
        updates += 1
        handle.cancel() // Reentrant cancellation during terminal publication must remain safe.
        if drained { coordinator = nil }
    }
    native.send(kind: 1, status: 7, pending: 2)
    assert(updates == 1 && !handle.isDrained && native.cancelCount == 1)
    native.send(kind: 2, status: 7, pending: 0)
    assert(updates == 2 && handle.isDrained && coordinator == nil && native.cancelCount == 1)
    handle.cancel(); assert(native.cancelCount == 1)
    handle.onChange = nil
}
do {
    let native = NativeDouble(); native.mode = .delayed
    var coordinator: ChromiumAuthenticationImport? = native.make()
    let target = coordinator!.createFreshSyntheticTarget(for: ProfileID(), persistSession: true)!
    let handle = coordinator!.submit(target, consuming: [try prepared()])
    coordinator = nil // The admitted native receipt, not its public owner, keeps context alive.
    var malformed = native.base; malformed.pending = 3
    native.callback?(native.context, &malformed)
    assert(handle.result == nil && !handle.isDrained)
    native.send(kind: 1, status: 9, pending: 1)
    var wrongDrain = native.base; wrongDrain.kind = 2; wrongDrain.status = 7
    native.callback?(native.context, &wrongDrain)
    assert(handle.result?.status == 9 && !handle.isDrained)
    native.send(kind: 2, status: 9, pending: 0)
    assert(handle.isDrained)
}
