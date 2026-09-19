// Package counter_test drives the whole arrangement end to end: a permanent
// realm, two implementation realms, and an unrelated realm that is refused.
//
// On chain, deploying an implementation is what registers it -- its init
// cross-calls counter.Register, the way r/gov/dao's loader realm sets the
// govDAO implementation. A test harness does not deliver those deployments as
// transactions, so the registrations an imported realm's init performs are
// not visible here; gno's own govDAO tests re-do the same init from the test
// file for exactly this reason. register below is that same accommodation:
// it stands in for the deploy transaction, and nothing else about the flow
// changes.
package counter_test

import (
	"strings"
	"testing"

	"gno.land/r/clockwork/counter"
	"gno.land/r/clockwork/counter/ext/v1"
	implv0 "gno.land/r/clockwork/counter/impl/v0"
	implv1 "gno.land/r/clockwork/counter/impl/v1"
	implv2 "gno.land/r/clockwork/counter/impl/v2"
	"gno.land/r/clockwork/intruder"
)

const (
	pathV0 = "gno.land/r/clockwork/counter/impl/v0"
	pathV1 = "gno.land/r/clockwork/counter/impl/v1"
	pathV2 = "gno.land/r/clockwork/counter/impl/v2"
	pathExt = "gno.land/r/clockwork/counter/ext/v1"
)

// TestUpgradeLifecycle is one story told in order: registering nominates,
// accepting serves, the count survives the swap, and rolling back brings the
// old behavior -- bug included -- straight back.
func TestUpgradeLifecycle(cur realm, t *testing.T) {
	admin := counter.Admin

	// Stand in for the two deployments.
	testing.SetRealm(testing.NewCodeRealm(pathV0))
	counter.Register(cross(cur), implv0.Instance())
	testing.SetRealm(testing.NewCodeRealm(pathV1))
	counter.Register(cross(cur), implv1.Instance())

	// Registering nominates. Nothing serves yet.
	if counter.LivePath() != "" {
		t.Fatalf("expected nothing live before the first Accept, got %s", counter.LivePath())
	}
	pending := counter.PendingPaths()
	if len(pending) != 2 || pending[0] != pathV0 || pending[1] != pathV1 {
		t.Fatalf("expected both implementations registered, got %v", pending)
	}

	// The authority accepts v0. This is the upgrade: a separate transaction
	// from the deployment, naming a path anyone can go and read.
	testing.SetRealm(testing.NewUserRealm(admin))
	counter.Accept(cross(cur), pathV0)

	if counter.LivePath() != pathV0 {
		t.Fatalf("expected %s live, got %s", pathV0, counter.LivePath())
	}

	// v0 applies the delta as given, including below zero. That is the bug.
	testing.SetRealm(testing.NewUserRealm(admin))
	if got := counter.Increment(cross(cur), 7); got != 7 {
		t.Errorf("expected 7, got %d", got)
	}
	testing.SetRealm(testing.NewUserRealm(admin))
	if got := counter.Increment(cross(cur), -10); got != -3 {
		t.Errorf("expected v0 to allow -3, got %d", got)
	}

	// Upgrade to v1. The count is not migrated, because it was never in v0:
	// it has been in the counter realm the whole time.
	testing.SetRealm(testing.NewUserRealm(admin))
	counter.Accept(cross(cur), pathV1)

	if counter.LivePath() != pathV1 {
		t.Fatalf("expected %s live, got %s", pathV1, counter.LivePath())
	}
	if got := counter.Count(); got != -3 {
		t.Fatalf("the count did not survive the upgrade: got %d, want -3", got)
	}
	if history := counter.HistoryPaths(); len(history) != 1 || history[0] != pathV0 {
		t.Errorf("expected v0 in history, got %v", history)
	}

	// v1 refuses to go below zero, and records that it had to.
	testing.SetRealm(testing.NewUserRealm(admin))
	if got := counter.Increment(cross(cur), -1); got != 0 {
		t.Errorf("expected v1 to clamp at 0, got %d", got)
	}
	testing.SetRealm(testing.NewUserRealm(admin))
	if got := counter.Increment(cross(cur), 4); got != 4 {
		t.Errorf("expected 4, got %d", got)
	}

	// Roll back. The count stays where v1 left it -- state does not travel
	// with the implementation -- and v0's missing floor is back.
	testing.SetRealm(testing.NewUserRealm(admin))
	counter.Rollback(cross(cur))

	if counter.LivePath() != pathV0 {
		t.Fatalf("expected %s live after rollback, got %s", pathV0, counter.LivePath())
	}
	if got := counter.Count(); got != 4 {
		t.Errorf("expected the count to stay at 4 across the rollback, got %d", got)
	}
	testing.SetRealm(testing.NewUserRealm(admin))
	if got := counter.Increment(cross(cur), -10); got != -6 {
		t.Errorf("expected the old behavior back, got %d", got)
	}

	// The displaced release returns to the pending set, so a fixed version
	// can be re-accepted without redeploying it.
	if pending := counter.PendingPaths(); len(pending) != 1 || pending[0] != pathV1 {
		t.Fatalf("expected v1 back in pending, got %v", pending)
	}
	testing.SetRealm(testing.NewUserRealm(admin))
	counter.Accept(cross(cur), pathV1)
	if counter.LivePath() != pathV1 {
		t.Fatalf("expected %s live again, got %s", pathV1, counter.LivePath())
	}

	// v1's own state stayed with v1 across the rollback and back: it still
	// remembers the single clamp from before. State a version keeps for
	// itself lives in that version's realm, which is the half the counter
	// realm cannot hold for it.
	testing.SetRealm(testing.NewUserRealm(admin))
	page := counter.Render(cross(cur), "")
	if !strings.Contains(page, "impl/v1") {
		t.Errorf("expected Render to name impl/v1, got:\n%s", page)
	}
	if !strings.Contains(page, "(1 so far)") {
		t.Errorf("expected v1 to still remember its one clamp, got:\n%s", page)
	}
}

func TestNonAuthorityCannotUpgrade(cur realm, t *testing.T) {
	stranger := address("g1us8428u2a5satrlxzagqqa5m6vmuze025anjlj")

	testing.SetRealm(testing.NewCodeRealm(pathV0))
	counter.Register(cross(cur), implv0.Instance())
	before := counter.LivePath()

	testing.SetRealm(testing.NewUserRealm(stranger))
	if abort := revive(func() { counter.Accept(cross(cur), pathV0) }); abort == nil {
		t.Fatal("a stranger was allowed to upgrade the realm")
	}
	if counter.LivePath() != before {
		t.Errorf("the refused upgrade still took effect: %s -> %s", before, counter.LivePath())
	}
}

// The state is handed out against a realm value, so a third realm holding a
// perfectly valid cur of its own is still refused -- it is refused precisely
// because that cur is its own.
func TestAnotherRealmCannotReachTheState(cur realm, t *testing.T) {
	if abort := revive(func() { intruder.Steal(cross(cur)) }); abort == nil {
		t.Error("an unrelated realm read the counter's state")
	}
	if abort := revive(func() { intruder.Tamper(cross(cur), 9999) }); abort == nil {
		t.Error("an unrelated realm wrote the counter's state")
	}
}

// TestExtensionAddsAnEntryPoint is the answer to "can the API grow?".
//
// counter's exported functions are fixed and it has no Decrement. ext/v1 was
// deployed later, declares an interface counter never heard of, asserts the
// live implementation to it, and serves a real MsgCall entry point that moves
// the same count in the same realm.
func TestExtensionAddsAnEntryPoint(cur realm, t *testing.T) {
	admin := counter.Admin

	// An implementation that satisfies both counter.Counter and ext's own
	// Decrementer. It imports neither ext nor knows the interface exists;
	// satisfaction is structural.
	testing.SetRealm(testing.NewCodeRealm(pathV2))
	counter.Register(cross(cur), implv2.Instance())
	testing.SetRealm(testing.NewUserRealm(admin))
	counter.Accept(cross(cur), pathV2)

	if !ext.Supported() {
		t.Fatal("impl/v2 should satisfy the interface ext/v1 declares")
	}

	// Satisfying the interface is not enough. Until the authority registers
	// ext/v1, the call reaches the state accessor and is refused there.
	for _, e := range counter.Extensions() {
		if e == pathExt {
			testing.SetRealm(testing.NewUserRealm(admin))
			counter.DropExtension(cross(cur), pathExt)
		}
	}
	if abort := revive(func() { ext.Decrement(cross(cur), 1) }); abort == nil {
		t.Error("an unregistered extension reached the state")
	}

	// One governance call, and the new entry point works.
	testing.SetRealm(testing.NewUserRealm(admin))
	counter.AddExtension(cross(cur), pathExt)

	before := counter.Count()
	testing.SetRealm(testing.NewUserRealm(admin))
	got := ext.Decrement(cross(cur), 3)

	if want := before - 3; got != want && !(want < 0 && got == 0) {
		t.Errorf("Decrement returned %d, want %d", got, want)
	}
	if counter.Count() != got {
		t.Errorf("the extension wrote somewhere else: counter.Count()=%d, Decrement returned %d",
			counter.Count(), got)
	}

	// Revoking it closes the entry point again without undeploying anything.
	testing.SetRealm(testing.NewUserRealm(admin))
	counter.DropExtension(cross(cur), pathExt)
	if abort := revive(func() { ext.Decrement(cross(cur), 1) }); abort == nil {
		t.Error("a revoked extension still reached the state")
	}
}

// An extension is only as available as the implementation currently serving.
func TestExtensionFailsUnderAnOlderImplementation(cur realm, t *testing.T) {
	admin := counter.Admin

	testing.SetRealm(testing.NewCodeRealm(pathV0))
	counter.Register(cross(cur), implv0.Instance())
	testing.SetRealm(testing.NewUserRealm(admin))
	counter.Accept(cross(cur), pathV0)
	testing.SetRealm(testing.NewUserRealm(admin))
	counter.AddExtension(cross(cur), pathExt)

	if ext.Supported() {
		t.Error("impl/v0 has no Decrement; Supported should say so")
	}
	if abort := revive(func() { ext.Decrement(cross(cur), 1) }); abort == nil {
		t.Error("Decrement worked under an implementation that cannot do it")
	}
}
