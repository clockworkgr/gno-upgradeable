// Package todo_test shows an application's API growing, and being described
// and checked while it does.
//
// As in the counter tests, registration is done explicitly: on chain an
// implementation's init registers it, but a test harness does not deliver
// deployments as transactions.
package todo_test

import (
	"strings"
	"testing"

	"gno.land/p/clockwork/app/v0"
	"gno.land/r/clockwork/todo"
	implv0 "gno.land/r/clockwork/todo/impl/v0"
	implv1 "gno.land/r/clockwork/todo/impl/v1"
)

const (
	pathV0 = "gno.land/r/clockwork/todo/impl/v0"
	pathV1 = "gno.land/r/clockwork/todo/impl/v1"
)

func TestTheApiGrowsAndIsDescribedWhileItDoes(cur realm, t *testing.T) {
	admin := todo.Admin

	testing.SetRealm(testing.NewCodeRealm(pathV0))
	todo.Register(cross(cur), implv0.Instance())
	testing.SetRealm(testing.NewUserRealm(admin))
	todo.Manage(cross(cur), "accept", pathV0)

	// The API is enumerable without reading any source.
	if got := strings.Join(todo.Verbs(), ","); got != "add,list" {
		t.Errorf("v0 verbs: %q", got)
	}
	if got := todo.Signature("add"); got != "add(text:string) -> int" {
		t.Errorf("v0 add signature: %q", got)
	}

	testing.SetRealm(testing.NewUserRealm(admin))
	if got := todo.Call(cross(cur), "add", "buy milk"); got != "1" {
		t.Errorf("expected task 1, got %q", got)
	}
	// A comma in a value survives, because the wire format is a CSV record
	// rather than a split on commas.
	testing.SetRealm(testing.NewUserRealm(admin))
	if got := todo.Call(cross(cur), "add", `"buy milk, eggs"`); got != "2" {
		t.Errorf("expected task 2, got %q", got)
	}
	testing.SetRealm(testing.NewUserRealm(admin))
	if list := todo.Call(cross(cur), "list", ""); !strings.Contains(list, "buy milk, eggs") {
		t.Errorf("the comma did not survive:\n%s", list)
	}

	// "done" is not declared yet, and the app says so before any handler runs.
	testing.SetRealm(testing.NewUserRealm(admin))
	if abort := revive(func() { todo.Call(cross(cur), "done", "1") }); abort == nil {
		t.Error("v0 should not answer done")
	}

	// Upgrade. The realm's source is untouched.
	testing.SetRealm(testing.NewCodeRealm(pathV1))
	todo.Register(cross(cur), implv1.Instance())
	testing.SetRealm(testing.NewUserRealm(admin))
	todo.Manage(cross(cur), "accept", pathV1)

	if got := strings.Join(todo.Verbs(), ","); got != "add,count,done,list" {
		t.Errorf("v1 verbs: %q", got)
	}
	if got := todo.Signature("done"); got != "done(id:int) -> string" {
		t.Errorf("v1 done signature: %q", got)
	}

	testing.SetRealm(testing.NewUserRealm(admin))
	if got := todo.Call(cross(cur), "done", "1"); got != "ok" {
		t.Errorf("done: %q", got)
	}
	testing.SetRealm(testing.NewUserRealm(admin))
	if got := todo.Call(cross(cur), "count", ""); got != "1" {
		t.Errorf("expected 1 task open, got %q", got)
	}

	// v0's tasks are still here, rendered with state v0 never knew about.
	testing.SetRealm(testing.NewUserRealm(admin))
	list := todo.Call(cross(cur), "list", "")
	if !strings.Contains(list, "[x] 0000000001 buy milk") ||
		!strings.Contains(list, "[ ] 0000000002 buy milk, eggs") {
		t.Errorf("v0's tasks did not survive the upgrade:\n%s", list)
	}
}

func TestSchemaJSONDescribesTheApi(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewCodeRealm(pathV1))
	todo.Register(cross(cur), implv1.Instance())
	testing.SetRealm(testing.NewUserRealm(todo.Admin))
	todo.Manage(cross(cur), "accept-breaking", pathV1)

	js := todo.SchemaJSON()
	for _, want := range []string{
		`"name":"add"`, `"name":"done"`, `"kind":"int"`,
		`"name":"text"`, `"result":"string"`, `"optional":false`,
	} {
		if !strings.Contains(js, want) {
			t.Errorf("expected %s in:\n%s", want, js)
		}
	}
}

// Validation happens in the app, before the handler runs, and the message
// names what was wrong.
func TestPayloadsAreCheckedBeforeDispatch(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewCodeRealm(pathV1))
	todo.Register(cross(cur), implv1.Instance())
	testing.SetRealm(testing.NewUserRealm(todo.Admin))
	todo.Manage(cross(cur), "accept-breaking", pathV1)

	cases := []struct{ verb, payload, why string }{
		{"nope", "", "an undeclared verb"},
		{"done", "not-a-number", "an int parameter given a word"},
		{"done", "", "a missing required parameter"},
		{"add", "a,b", "too many fields"},
		{"count", "surprise", "a payload for a verb that takes none"},
	}
	for _, c := range cases {
		testing.SetRealm(testing.NewUserRealm(todo.Admin))
		verb, payload := c.verb, c.payload
		if abort := revive(func() { todo.Call(cross(cur), verb, payload) }); abort == nil {
			t.Errorf("%s was accepted", c.why)
		}
	}
}

// A schema makes an upgrade checkable: a handler that would break a caller is
// refused by default, and the refusal names what breaks.
type breakingHandler struct{}

var breakingSchema = app.NewSchema(
	// Same verb name, different parameter kind: every caller passing text
	// would start failing.
	app.Op("add", "", app.KindInt, app.P("text", app.KindInt, "")),
)

func (breakingHandler) Schema() *app.Schema { return breakingSchema }

func (breakingHandler) Handle(_ int, rlm realm, args *app.Args) string { return "" }

func TestBreakingUpgradeIsRefusedByDefault(cur realm, t *testing.T) {
	const badPath = "gno.land/r/clockwork/todo/impl/v9"

	testing.SetRealm(testing.NewCodeRealm(pathV1))
	todo.Register(cross(cur), implv1.Instance())
	testing.SetRealm(testing.NewUserRealm(todo.Admin))
	todo.Manage(cross(cur), "accept-breaking", pathV1)

	testing.SetRealm(testing.NewCodeRealm(badPath))
	todo.Register(cross(cur), breakingHandler{})

	testing.SetRealm(testing.NewUserRealm(todo.Admin))
	if abort := revive(func() { todo.Manage(cross(cur), "accept", badPath) }); abort == nil {
		t.Fatal("a breaking upgrade was accepted")
	}
	if todo.Verbs()[0] != "add" || len(todo.Verbs()) != 4 {
		t.Errorf("the refused upgrade still took effect: %v", todo.Verbs())
	}

	// The authority can still override, deliberately.
	testing.SetRealm(testing.NewUserRealm(todo.Admin))
	todo.Manage(cross(cur), "accept-breaking", badPath)
	if got := todo.Signature("add"); got != "add(text:int) -> int" {
		t.Errorf("accept-breaking should have gone through, got %q", got)
	}

	// Put it back.
	testing.SetRealm(testing.NewUserRealm(todo.Admin))
	todo.Manage(cross(cur), "rollback", "")
}

func TestHandlerWithoutASchemaIsRefused(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/clockwork/todo/impl/v8"))
	if abort := revive(func() { todo.Register(cross(cur), emptyHandler{}) }); abort == nil {
		t.Error("a handler declaring no verbs was registered")
	}
}

type emptyHandler struct{}

func (emptyHandler) Schema() *app.Schema                            { return app.NewSchema() }
func (emptyHandler) Handle(_ int, rlm realm, args *app.Args) string { return "" }

func TestStoreRefusesAnUnrelatedRealm(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/clockwork/intruder"))
	if abort := revive(func() { todo.Store(0, cur) }); abort == nil {
		t.Error("the store was handed to a realm that is neither the app nor an extension")
	}
}

func TestNonAuthorityCannotManage(cur realm, t *testing.T) {
	stranger := address("g1us8428u2a5satrlxzagqqa5m6vmuze025anjlj")
	testing.SetRealm(testing.NewUserRealm(stranger))
	if abort := revive(func() { todo.Manage(cross(cur), "freeze", "") }); abort == nil {
		t.Error("a stranger froze the app")
	}
}

func TestUnknownAdminVerbIsRefused(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(todo.Admin))
	if abort := revive(func() { todo.Manage(cross(cur), "selfdestruct", "") }); abort == nil {
		t.Error("an unknown admin verb was accepted")
	}
}
