package counter

// count is the realm's state. It lives here, in the realm at the permanent
// path, and not in any implementation -- which is the whole reason the proxy
// in counter.gno is worth having. Accepting a new implementation replaces the
// code that reads and writes this value; it does not touch the value.
//
// It is a bare package variable rather than a struct, because there is only
// one number and the accessor below, not the field, is what enforces who may
// touch it.
var count int64

// StateRef is a permission to read and write the count, handed to code running
// on this realm's cur. It is NOT the state -- it carries the caller's realm
// value and re-checks it on every operation.
//
// That is what makes state access safe against a hostile implementation. An
// earlier version handed back a *State pointer, which an accepted impl could
// stash in a package variable and keep writing through after it was rolled
// back or the realm was frozen. A StateRef cannot be stashed: assigning it to
// realm state persists the realm value it holds, which the VM refuses
// ("cannot persist realm value"), aborting the transaction. Nor can it be
// replayed: a StateRef whose frame has returned fails IsCurrent(). So the
// capability lives and dies with the exact call that obtained it.
type StateRef struct {
	rlm realm
}

// Store hands out a StateRef to the live implementation, and to any realm the
// authority has registered as an extension.
//
// A third realm calling Store with its own cur presents its own PkgPath and is
// refused -- unless it is a registered extension, which is how this realm's
// API grows after the fact. See ext/v1 and impl/v2, and the "extending a
// frozen API" pattern in the repository docs.
func Store(_ int, rlm realm) *StateRef {
	assertStateAccess(0, rlm)
	return &StateRef{rlm: rlm}
}

// Count returns the current value.
func (r *StateRef) Count() int64 {
	assertStateAccess(0, r.rlm)
	return count
}

// Add applies delta and returns the new value.
func (r *StateRef) Add(delta int64) int64 {
	assertStateAccess(0, r.rlm)
	count += delta
	return count
}

// Set replaces the value.
func (r *StateRef) Set(v int64) {
	assertStateAccess(0, r.rlm)
	count = v
}

// assertStateAccess panics unless rlm is a live cur belonging to this realm or
// a registered extension. It runs when the StateRef is handed out and again on
// every read and write, so a stale or foreign ref is refused every time.
func assertStateAccess(_ int, rlm realm) {
	if !rlm.IsCurrent() {
		panic("counter: realm value is not the caller's live cur")
	}
	if caller := rlm.PkgPath(); caller != selfPath && !proxy.IsExtension(caller) {
		panic("counter: state is reachable only through " + selfPath +
			" or a registered extension, not from " + caller)
	}
}
