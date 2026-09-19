package upgradeable

import "testing"

const (
	alice = address("g1vh7krmmzfua5xjmkatvmx09z37w34lsvd2mxa5")
	bob   = address("g1us8428u2a5satrlxzagqqa5m6vmuze025anjlj")
	daoP  = "gno.land/r/demo/gov"
	altP  = "gno.land/r/demo/gov2"
)

func TestAddrAuthorityMatchesOnlyItsAddress(t *testing.T) {
	a := NewAddrAuthority(alice)
	if !a.Authorized(alice, "") {
		t.Error("alice's own direct call should be authorized")
	}
	if !a.Authorized(alice, daoP) {
		t.Error("a realm acting at alice's address should be authorized")
	}
	if a.Authorized(bob, "") {
		t.Error("bob should not be authorized")
	}
	if a.Authorized("", "") {
		t.Error("an empty address should never be authorized")
	}
}

func TestNewAddrAuthorityRejectsInvalidAddress(t *testing.T) {
	assertPanics(t, ErrBadAddress, func() { NewAddrAuthority("") })
	assertPanics(t, ErrBadAddress, func() { NewAddrAuthority("not-an-address") })
}

func TestRealmAuthorityMatchesPathNotAddress(t *testing.T) {
	a := NewRealmAuthority(daoP)
	if !a.Authorized("", daoP) {
		t.Error("the listed realm should be authorized")
	}
	if a.Authorized(alice, altP) {
		t.Error("an unlisted realm should not be authorized")
	}
}

// A user call carries an empty PkgPath. If a path check treated that as a
// path, every direct transaction would pass it.
func TestRealmAuthorityRejectsUserCalls(t *testing.T) {
	a := NewRealmAuthority(daoP)
	if a.Authorized(alice, "") {
		t.Error("a user call must not satisfy a realm authority")
	}
}

func TestNewRealmAuthorityRejectsUnusablePaths(t *testing.T) {
	assertPanics(t, ErrNoAuthority, func() { NewRealmAuthority() })
	assertPanics(t, ErrBadRealmPath, func() { NewRealmAuthority("") })
	assertPanics(t, ErrBadRealmPath, func() { NewRealmAuthority(daoP, "") })
	assertPanics(t, ErrBadRealmPath, func() { NewRealmAuthority(" " + daoP) })
	assertPanics(t, ErrBadRealmPath, func() { NewRealmAuthority(daoP + " ") })
}

func TestRealmAuthorityPathsIsACopy(t *testing.T) {
	a := NewRealmAuthority(daoP)
	got := a.Paths()
	got[0] = altP
	if a.Paths()[0] != daoP {
		t.Error("mutating the returned slice changed the authority")
	}
}

func TestAnyOf(t *testing.T) {
	a := NewAnyOf(NewAddrAuthority(alice), NewRealmAuthority(daoP))
	if !a.Authorized(alice, "") {
		t.Error("the address member should authorize alice")
	}
	if !a.Authorized(bob, daoP) {
		t.Error("the realm member should authorize the dao")
	}
	if a.Authorized(bob, altP) {
		t.Error("neither member authorizes this caller")
	}
}

func TestNewAnyOfRejectsEmptyOrNilMembers(t *testing.T) {
	assertPanics(t, ErrNoAuthority, func() { NewAnyOf() })
	assertPanics(t, ErrNoAuthority, func() { NewAnyOf(NewAddrAuthority(alice), nil) })
}

// assertAborts runs fn and fails unless a panic crossed a realm boundary
// inside it with the value want.
//
// A panic that crosses a realm boundary aborts the machine rather than
// unwinding, so recover() cannot see it -- Gno does not let one realm catch
// another's failure, because a recovered cross-realm panic leaves state
// half-written. revive is the testing-mode builtin that reports the abort
// instead of taking the program down with it.
func assertAborts(t *testing.T, want error, fn func()) {
	t.Helper()
	abort := revive(fn)
	if abort == nil {
		t.Errorf("expected abort %v, got none", want)
		return
	}
	got, ok := abort.(error)
	if !ok {
		t.Errorf("expected abort %v, got non-error %v", want, abort)
		return
	}
	if got != want {
		t.Errorf("expected abort %v, got %v", want, got)
	}
}

// assertPanics runs fn and fails unless it panicked with want. Use it only
// where the panic stays inside one realm; see assertAborts otherwise.
func assertPanics(t *testing.T, want error, fn func()) {
	t.Helper()
	defer func() {
		r := recover()
		if r == nil {
			t.Errorf("expected panic %v, got none", want)
			return
		}
		got, ok := r.(error)
		if !ok {
			t.Errorf("expected panic %v, got non-error %v", want, r)
			return
		}
		if got != want {
			t.Errorf("expected panic %v, got %v", want, got)
		}
	}()
	fn()
}
