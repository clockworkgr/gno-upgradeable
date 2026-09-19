package app

import "testing"

// The store accessor must re-run its access check on every operation, not only
// when it is handed out. This is what makes a retained accessor useless the
// moment its frame is no longer the app's live cur — the in-CI half of the
// capability-leak fix (the other half, that the accessor cannot be persisted
// because it holds a realm value, is a VM guarantee exercised on chain).
//
// We build an accessor whose captured cur does not match the app's bound self,
// then confirm every operation is refused — proving the guard runs per op.
func TestStoreOpsRecheckAccessEveryCall(cur realm, t *testing.T) {
	a := New(Owner(address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5")))
	a.self = "gno.land/r/someone/else" // bound elsewhere; cur's path won't match

	st := &Store{app: a, rlm: cur} // a well-formed accessor, wrong identity

	ops := []struct {
		name string
		call func()
	}{
		{"Get", func() { st.Get("k") }},
		{"Has", func() { st.Has("k") }},
		{"Set", func() { st.Set("k", "v") }},
		{"Delete", func() { st.Delete("k") }},
		{"Len", func() { st.Len() }},
		{"Keys", func() { st.Keys() }},
		{"KeysWithPrefix", func() { st.KeysWithPrefix("k") }},
		{"GetInt", func() { st.GetInt("k") }},
		{"SetInt", func() { st.SetInt("k", 1) }},
		{"AddInt", func() { st.AddInt("k", 1) }},
	}
	for _, op := range ops {
		if !panics(op.call) {
			t.Errorf("%s did not re-check access; a retained accessor could use it", op.name)
		}
	}
}

// panics reports whether fn panicked (same-realm panic, catchable by recover).
func panics(fn func()) (did bool) {
	defer func() {
		if recover() != nil {
			did = true
		}
	}()
	fn()
	return false
}

// Render must not panic and must report the key count via the data layer
// (this locks the a.data.length() path after the store refactor).
func TestRenderReportsStateSize(cur realm, t *testing.T) {
	a := New(Owner(address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5")))
	a.self = "gno.land/r/x/app"
	a.data.set("one", "1")
	a.data.set("two", "2")
	page := a.Render("")
	if !contains(page, "State: **2** keys") {
		t.Errorf("Render did not report state size:\n%s", page)
	}
}

func contains(s, sub string) bool {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}
