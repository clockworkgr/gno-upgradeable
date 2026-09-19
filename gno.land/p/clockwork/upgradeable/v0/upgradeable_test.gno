package upgradeable

import (
	"chain/runtime"
	"testing"
)

// testing.NewCodeRealm only builds /r/ paths, and the Proxy under test is
// held by this /p/ package, so no candidate here can satisfy the nesting rule
// of New. The lifecycle tests therefore use NewOpen; the rule itself is
// covered by TestIsNested and by TestNewRequiresCandidatesToBeNested.
const (
	implA   = "gno.land/r/demo/app/impl/v0"
	implB   = "gno.land/r/demo/app/impl/v1"
	outside = "gno.land/r/demo/elsewhere"
)

type fakeImpl struct{ name string }

// Each call below is two lines: testing.SetRealm decides who the caller will
// be, and the crossing literal makes the call as them. Both have to happen in
// the frame that owns cur -- SetRealm inside a helper sets that helper's
// frame, which cross(cur) does not look at.

func TestNewRejectsNilAuthority(t *testing.T) {
	assertPanics(t, ErrNoAuthority, func() { New(nil) })
	assertPanics(t, ErrNoAuthority, func() { NewOpen(nil) })
}

func TestImplPanicsBeforeAnythingIsAccepted(t *testing.T) {
	p := NewOpen(NewAddrAuthority(alice))
	if _, ok := p.TryImpl(); ok {
		t.Error("a fresh proxy should have no implementation")
	}
	if p.LivePath() != "" {
		t.Error("a fresh proxy should have no live path")
	}
	assertPanics(t, ErrNoImpl, func() { p.Impl() })
}

// The recorded path comes off the crossing frame, so it names the realm the
// code actually lives at rather than whatever the caller claims.
func TestProposeRecordsTheCallingRealmsPath(cur realm, t *testing.T) {
	p := NewOpen(NewAddrAuthority(alice))

	testing.SetRealm(testing.NewCodeRealm(implA))
	func(cur realm) { p.Propose(0, cur, &fakeImpl{name: "a"}) }(cross(cur))

	pending := p.Pending()
	if len(pending) != 1 {
		t.Fatalf("expected 1 candidate, got %d", len(pending))
	}
	if pending[0].PkgPath() != implA {
		t.Errorf("expected %s, got %s", implA, pending[0].PkgPath())
	}
	if got := pending[0].Impl().(*fakeImpl).name; got != "a" {
		t.Errorf("expected impl a, got %s", got)
	}
}

func TestProposeRejectsUserCalls(cur realm, t *testing.T) {
	p := NewOpen(NewAddrAuthority(alice))

	testing.SetRealm(testing.NewUserRealm(alice))
	assertAborts(t, ErrNotARealm, func() {
		func(cur realm) { p.Propose(0, cur, &fakeImpl{}) }(cross(cur))
	})
}

// An `gnokey maketx run` script crosses from /e/<addr>/run, which has a
// non-empty PkgPath and would otherwise be filed as a candidate path that
// stops existing when the transaction ends.
func TestProposeRejectsEphemeralRealms(cur realm, t *testing.T) {
	p := NewOpen(NewAddrAuthority(alice))

	ephemeral := "gno.land/e/" + alice.String() + "/run"
	testing.SetRealm(runtime.NewRealm(alice, ephemeral))
	assertAborts(t, ErrNotARealm, func() {
		func(cur realm) { p.Propose(0, cur, &fakeImpl{}) }(cross(cur))
	})
	if len(p.Pending()) != 0 {
		t.Error("an ephemeral realm was filed as a candidate")
	}
}

func TestProposeRejectsNilImplementations(cur realm, t *testing.T) {
	p := NewOpen(NewAddrAuthority(alice))

	testing.SetRealm(testing.NewCodeRealm(implA))
	assertAborts(t, ErrNilImpl, func() {
		func(cur realm) { p.Propose(0, cur, nil) }(cross(cur))
	})
}

func TestIsNested(t *testing.T) {
	const app = "gno.land/r/you/app"
	cases := []struct {
		child string
		want  bool
	}{
		{app + "/impl/v0", true},
		{app + "/impl/v1", true},
		{app, true},
		{"gno.land/r/you/appliance/impl/v0", false},
		{"gno.land/r/someone/app/impl/v0", false},
		{"gno.land/r/you", false},
		{"", false},
	}
	for _, c := range cases {
		if got := isNested(app, c.child); got != c.want {
			t.Errorf("isNested(%s, %s) = %t, want %t", app, c.child, got, c.want)
		}
	}
}

func TestNewRequiresCandidatesToBeNested(cur realm, t *testing.T) {
	p := New(NewAddrAuthority(alice))

	testing.SetRealm(testing.NewCodeRealm(outside))
	assertAborts(t, ErrNotNested, func() {
		func(cur realm) { p.Propose(0, cur, &fakeImpl{}) }(cross(cur))
	})
}

func TestNewOpenAcceptsAnyRealm(cur realm, t *testing.T) {
	p := NewOpen(NewAddrAuthority(alice))

	testing.SetRealm(testing.NewCodeRealm(outside))
	func(cur realm) { p.Propose(0, cur, &fakeImpl{}) }(cross(cur))

	if len(p.Pending()) != 1 {
		t.Error("NewOpen should accept a candidate from outside the namespace")
	}
}

// A realm re-registering replaces its own candidate: the retry path after a
// deployment that nobody accepted.
func TestProposeReplacesTheSameRealmsCandidate(cur realm, t *testing.T) {
	p := NewOpen(NewAddrAuthority(alice))

	testing.SetRealm(testing.NewCodeRealm(implA))
	func(cur realm) { p.Propose(0, cur, &fakeImpl{name: "first"}) }(cross(cur))
	testing.SetRealm(testing.NewCodeRealm(implA))
	func(cur realm) { p.Propose(0, cur, &fakeImpl{name: "second"}) }(cross(cur))

	pending := p.Pending()
	if len(pending) != 1 {
		t.Fatalf("expected 1 candidate, got %d", len(pending))
	}
	if got := pending[0].Impl().(*fakeImpl).name; got != "second" {
		t.Errorf("expected the later registration to win, got %s", got)
	}
}

func TestPendingIsSortedByPath(cur realm, t *testing.T) {
	p := NewOpen(NewAddrAuthority(alice))

	testing.SetRealm(testing.NewCodeRealm(implB))
	func(cur realm) { p.Propose(0, cur, &fakeImpl{name: "b"}) }(cross(cur))
	testing.SetRealm(testing.NewCodeRealm(implA))
	func(cur realm) { p.Propose(0, cur, &fakeImpl{name: "a"}) }(cross(cur))

	pending := p.Pending()
	if len(pending) != 2 {
		t.Fatalf("expected 2 candidates, got %d", len(pending))
	}
	if pending[0].PkgPath() != implA || pending[1].PkgPath() != implB {
		t.Errorf("expected sorted order, got %s then %s",
			pending[0].PkgPath(), pending[1].PkgPath())
	}
}

func TestAcceptMakesACandidateLive(cur realm, t *testing.T) {
	p := NewOpen(NewAddrAuthority(alice))

	testing.SetRealm(testing.NewCodeRealm(implA))
	func(cur realm) { p.Propose(0, cur, &fakeImpl{name: "a"}) }(cross(cur))
	testing.SetRealm(testing.NewUserRealm(alice))
	func(cur realm) { p.Accept(0, cur, implA) }(cross(cur))

	if p.LivePath() != implA {
		t.Errorf("expected %s live, got %s", implA, p.LivePath())
	}
	if got := p.Impl().(*fakeImpl).name; got != "a" {
		t.Errorf("expected impl a to serve, got %s", got)
	}
	if len(p.Pending()) != 0 {
		t.Error("an accepted candidate should leave the pending set")
	}
	if len(p.History()) != 0 {
		t.Error("the first acceptance replaces nothing, so history stays empty")
	}
}

func TestAcceptFilesTheReplacedReleaseInHistory(cur realm, t *testing.T) {
	p := NewOpen(NewAddrAuthority(alice))

	testing.SetRealm(testing.NewCodeRealm(implA))
	func(cur realm) { p.Propose(0, cur, &fakeImpl{name: "a"}) }(cross(cur))
	testing.SetRealm(testing.NewUserRealm(alice))
	func(cur realm) { p.Accept(0, cur, implA) }(cross(cur))

	testing.SetRealm(testing.NewCodeRealm(implB))
	func(cur realm) { p.Propose(0, cur, &fakeImpl{name: "b"}) }(cross(cur))
	testing.SetRealm(testing.NewUserRealm(alice))
	func(cur realm) { p.Accept(0, cur, implB) }(cross(cur))

	if p.LivePath() != implB {
		t.Errorf("expected %s live, got %s", implB, p.LivePath())
	}
	history := p.History()
	if len(history) != 1 || history[0].PkgPath() != implA {
		t.Errorf("expected %s in history, got %v", implA, history)
	}
}

func TestAcceptRefusesAnUnauthorizedCaller(cur realm, t *testing.T) {
	p := NewOpen(NewAddrAuthority(alice))

	testing.SetRealm(testing.NewCodeRealm(implA))
	func(cur realm) { p.Propose(0, cur, &fakeImpl{}) }(cross(cur))

	testing.SetRealm(testing.NewUserRealm(bob))
	assertAborts(t, ErrUnauthorized, func() {
		func(cur realm) { p.Accept(0, cur, implA) }(cross(cur))
	})
	if p.LivePath() != "" {
		t.Error("the refused upgrade still took effect")
	}
}

func TestAcceptRefusesAnUnregisteredPath(cur realm, t *testing.T) {
	p := NewOpen(NewAddrAuthority(alice))

	testing.SetRealm(testing.NewUserRealm(alice))
	assertAborts(t, ErrUnknownPath, func() {
		func(cur realm) { p.Accept(0, cur, implA) }(cross(cur))
	})
}

func TestRollbackRestoresThePreviousReleaseAndRequeuesTheCurrent(cur realm, t *testing.T) {
	p := NewOpen(NewAddrAuthority(alice))

	testing.SetRealm(testing.NewCodeRealm(implA))
	func(cur realm) { p.Propose(0, cur, &fakeImpl{name: "a"}) }(cross(cur))
	testing.SetRealm(testing.NewUserRealm(alice))
	func(cur realm) { p.Accept(0, cur, implA) }(cross(cur))

	testing.SetRealm(testing.NewCodeRealm(implB))
	func(cur realm) { p.Propose(0, cur, &fakeImpl{name: "b"}) }(cross(cur))
	testing.SetRealm(testing.NewUserRealm(alice))
	func(cur realm) { p.Accept(0, cur, implB) }(cross(cur))

	testing.SetRealm(testing.NewUserRealm(alice))
	func(cur realm) { p.Rollback(0, cur) }(cross(cur))

	if p.LivePath() != implA {
		t.Errorf("expected %s live after rollback, got %s", implA, p.LivePath())
	}
	if got := p.Impl().(*fakeImpl).name; got != "a" {
		t.Errorf("expected impl a to serve again, got %s", got)
	}
	if len(p.History()) != 0 {
		t.Error("rollback should consume the history entry it restored")
	}
	pending := p.Pending()
	if len(pending) != 1 || pending[0].PkgPath() != implB {
		t.Errorf("the rolled-back release should return to pending, got %v", pending)
	}
}

func TestRollbackNeedsSomethingToRollBackTo(cur realm, t *testing.T) {
	p := NewOpen(NewAddrAuthority(alice))

	testing.SetRealm(testing.NewCodeRealm(implA))
	func(cur realm) { p.Propose(0, cur, &fakeImpl{}) }(cross(cur))
	testing.SetRealm(testing.NewUserRealm(alice))
	func(cur realm) { p.Accept(0, cur, implA) }(cross(cur))

	testing.SetRealm(testing.NewUserRealm(alice))
	assertAborts(t, ErrNoHistory, func() {
		func(cur realm) { p.Rollback(0, cur) }(cross(cur))
	})
}

func TestForgetDropsHistoryAndWithItRollback(cur realm, t *testing.T) {
	p := NewOpen(NewAddrAuthority(alice))

	testing.SetRealm(testing.NewCodeRealm(implA))
	func(cur realm) { p.Propose(0, cur, &fakeImpl{name: "a"}) }(cross(cur))
	testing.SetRealm(testing.NewUserRealm(alice))
	func(cur realm) { p.Accept(0, cur, implA) }(cross(cur))

	testing.SetRealm(testing.NewCodeRealm(implB))
	func(cur realm) { p.Propose(0, cur, &fakeImpl{name: "b"}) }(cross(cur))
	testing.SetRealm(testing.NewUserRealm(alice))
	func(cur realm) { p.Accept(0, cur, implB) }(cross(cur))

	testing.SetRealm(testing.NewUserRealm(alice))
	func(cur realm) { p.Forget(0, cur) }(cross(cur))

	if len(p.History()) != 0 {
		t.Error("Forget should empty the history")
	}
	testing.SetRealm(testing.NewUserRealm(alice))
	assertAborts(t, ErrNoHistory, func() {
		func(cur realm) { p.Rollback(0, cur) }(cross(cur))
	})
}

// A realm may always drop its own candidate; anyone else's needs authority.
func TestWithdraw(cur realm, t *testing.T) {
	p := NewOpen(NewAddrAuthority(alice))

	testing.SetRealm(testing.NewCodeRealm(implA))
	func(cur realm) { p.Propose(0, cur, &fakeImpl{}) }(cross(cur))

	testing.SetRealm(testing.NewCodeRealm(implB))
	assertAborts(t, ErrUnauthorized, func() {
		func(cur realm) { p.Withdraw(0, cur, implA) }(cross(cur))
	})

	testing.SetRealm(testing.NewCodeRealm(implA))
	func(cur realm) { p.Withdraw(0, cur, implA) }(cross(cur))
	if len(p.Pending()) != 0 {
		t.Error("a realm should be able to withdraw its own candidate")
	}

	testing.SetRealm(testing.NewCodeRealm(implA))
	func(cur realm) { p.Propose(0, cur, &fakeImpl{}) }(cross(cur))
	testing.SetRealm(testing.NewUserRealm(alice))
	func(cur realm) { p.Withdraw(0, cur, implA) }(cross(cur))
	if len(p.Pending()) != 0 {
		t.Error("the authority should be able to withdraw any candidate")
	}
}

func TestTransferAuthorityMovesThePowerToUpgrade(cur realm, t *testing.T) {
	p := NewOpen(NewAddrAuthority(alice))

	testing.SetRealm(testing.NewUserRealm(alice))
	func(cur realm) { p.TransferAuthority(0, cur, NewAddrAuthority(bob)) }(cross(cur))

	testing.SetRealm(testing.NewCodeRealm(implB))
	func(cur realm) { p.Propose(0, cur, &fakeImpl{}) }(cross(cur))

	testing.SetRealm(testing.NewUserRealm(alice))
	assertAborts(t, ErrUnauthorized, func() {
		func(cur realm) { p.Accept(0, cur, implB) }(cross(cur))
	})

	testing.SetRealm(testing.NewUserRealm(bob))
	func(cur realm) { p.Accept(0, cur, implB) }(cross(cur))
	if p.LivePath() != implB {
		t.Error("the new authority should be able to upgrade")
	}
}

func TestTransferAuthorityRefusesNil(cur realm, t *testing.T) {
	p := NewOpen(NewAddrAuthority(alice))

	testing.SetRealm(testing.NewUserRealm(alice))
	assertAborts(t, ErrNoAuthority, func() {
		func(cur realm) { p.TransferAuthority(0, cur, nil) }(cross(cur))
	})
}

// Freezing with nothing live would leave the realm permanently unable to
// answer a call, so it is refused.
func TestFreezeRefusesAnEmptyProxy(cur realm, t *testing.T) {
	p := NewOpen(NewAddrAuthority(alice))

	testing.SetRealm(testing.NewUserRealm(alice))
	assertAborts(t, ErrNoImpl, func() {
		func(cur realm) { p.Freeze(0, cur) }(cross(cur))
	})
}

func TestFreezeEndsEveryPathToChange(cur realm, t *testing.T) {
	p := NewOpen(NewAddrAuthority(alice))

	testing.SetRealm(testing.NewCodeRealm(implA))
	func(cur realm) { p.Propose(0, cur, &fakeImpl{name: "a"}) }(cross(cur))
	testing.SetRealm(testing.NewUserRealm(alice))
	func(cur realm) { p.Accept(0, cur, implA) }(cross(cur))
	testing.SetRealm(testing.NewCodeRealm(implB))
	func(cur realm) { p.Propose(0, cur, &fakeImpl{name: "b"}) }(cross(cur))

	testing.SetRealm(testing.NewUserRealm(alice))
	func(cur realm) { p.Freeze(0, cur) }(cross(cur))

	if !p.Frozen() {
		t.Fatal("expected the proxy to be frozen")
	}
	if p.LivePath() != implA {
		t.Error("freezing should leave the live implementation serving")
	}
	if got := p.Impl().(*fakeImpl).name; got != "a" {
		t.Errorf("expected impl a to keep serving, got %s", got)
	}
	if len(p.Pending()) != 0 {
		t.Error("freezing should clear candidates that can never be accepted")
	}

	testing.SetRealm(testing.NewUserRealm(alice))
	assertAborts(t, ErrFrozen, func() {
		func(cur realm) { p.Accept(0, cur, implB) }(cross(cur))
	})
	testing.SetRealm(testing.NewUserRealm(alice))
	assertAborts(t, ErrFrozen, func() {
		func(cur realm) { p.Rollback(0, cur) }(cross(cur))
	})
	testing.SetRealm(testing.NewUserRealm(alice))
	assertAborts(t, ErrFrozen, func() {
		func(cur realm) { p.Freeze(0, cur) }(cross(cur))
	})
	testing.SetRealm(testing.NewUserRealm(alice))
	assertAborts(t, ErrFrozen, func() {
		func(cur realm) { p.TransferAuthority(0, cur, NewAddrAuthority(bob)) }(cross(cur))
	})
	testing.SetRealm(testing.NewCodeRealm(implB))
	assertAborts(t, ErrFrozen, func() {
		func(cur realm) { p.Propose(0, cur, &fakeImpl{}) }(cross(cur))
	})
}
