package impl_test

import (
	"testing"

	"gno.land/r/yourname/myapp"
	implv0 "gno.land/r/yourname/myapp/impl/v0"
)

const path = "gno.land/r/yourname/myapp/impl/v0"

// Registration is explicit here because a test harness does not deliver
// deployments as transactions; on chain, impl's init does it.
func setup(cur realm, t *testing.T) {
	t.Helper()
	testing.SetRealm(testing.NewCodeRealm(path))
	myapp.Register(cross(cur), implv0.Instance())
	testing.SetRealm(testing.NewUserRealm(myapp.Admin))
	myapp.Manage(cross(cur), "accept-breaking", path)
}

func TestTemplateWorks(cur realm, t *testing.T) {
	setup(cur, t)

	testing.SetRealm(testing.NewUserRealm(myapp.Admin))
	if got := myapp.Call(cross(cur), "ping", ""); got != "pong" {
		t.Errorf("ping: %q", got)
	}
	testing.SetRealm(testing.NewUserRealm(myapp.Admin))
	myapp.Call(cross(cur), "set", "colour,blue")
	testing.SetRealm(testing.NewUserRealm(myapp.Admin))
	if got := myapp.Call(cross(cur), "get", "colour"); got != "blue" {
		t.Errorf("get: %q", got)
	}
}

func TestTemplateApiIsEnumerable(cur realm, t *testing.T) {
	setup(cur, t)
	if got := len(myapp.Verbs()); got != 3 {
		t.Errorf("expected 3 verbs, got %d: %v", got, myapp.Verbs())
	}
	if got := myapp.Signature("set"); got != "set(key:string, value:string) -> none" {
		t.Errorf("set signature: %q", got)
	}
}

func TestTemplateChecksPayloads(cur realm, t *testing.T) {
	setup(cur, t)
	testing.SetRealm(testing.NewUserRealm(myapp.Admin))
	if abort := revive(func() { myapp.Call(cross(cur), "set", "only-one-field") }); abort == nil {
		t.Error("a missing parameter was accepted")
	}
}
