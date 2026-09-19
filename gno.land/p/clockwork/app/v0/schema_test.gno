package app

import (
	"strings"
	"testing"
)

func TestKindParse(t *testing.T) {
	cases := []struct {
		k    Kind
		v    string
		ok   bool
	}{
		{KindString, "anything at all", true},
		{KindInt, "42", true},
		{KindInt, "-1", true},
		{KindInt, "4.2", false},
		{KindInt, "", false},
		{KindInt, "abc", false},
		{KindBool, "true", true},
		{KindBool, "false", true},
		{KindBool, "TRUE", false},
		{KindBool, "1", false},
		{KindAddress, "g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5", true},
		{KindAddress, "not-an-address", false},
		{KindAddress, "", false},
	}
	for _, c := range cases {
		err := c.k.parse(c.v)
		if (err == nil) != c.ok {
			t.Errorf("%s.parse(%q): ok=%t, err=%v", c.k, c.v, c.ok, err)
		}
	}
}

func TestNewSchemaSortsAndLooksUp(t *testing.T) {
	s := NewSchema(
		Op("zeta", "", KindString),
		Op("alpha", "", KindInt, P("n", KindInt, "")),
	)
	names := s.Names()
	if len(names) != 2 || names[0] != "alpha" || names[1] != "zeta" {
		t.Errorf("expected sorted names, got %v", names)
	}
	v, ok := s.Lookup("alpha")
	if !ok || len(v.Params) != 1 || v.Params[0].Name != "n" {
		t.Errorf("Lookup(alpha) = %v, %t", v, ok)
	}
	if _, ok := s.Lookup("missing"); ok {
		t.Error("Lookup should report a missing verb")
	}
}

// Every one of these is an authoring mistake that would otherwise produce a
// handler that mis-describes itself forever.
func TestNewSchemaRejectsUnservableDeclarations(t *testing.T) {
	assertPanicsWith(t, "duplicate verb", func() {
		NewSchema(Op("a", "", KindString), Op("a", "", KindString))
	})
	assertPanicsWith(t, "non-blank", func() { NewSchema(Op("", "", KindString)) })
	assertPanicsWith(t, "non-blank", func() { NewSchema(Op(" a", "", KindString)) })
	assertPanicsWith(t, "unknown result kind", func() { NewSchema(Op("a", "", Kind("wat"))) })
	assertPanicsWith(t, "unusable kind", func() {
		NewSchema(Op("a", "", KindString, P("p", KindNone, "")))
	})
	assertPanicsWith(t, "duplicate parameter", func() {
		NewSchema(Op("a", "", KindString, P("p", KindString, ""), P("p", KindInt, "")))
	})
	// Positional encoding: a required parameter after an optional one could
	// never be supplied without also supplying the optional.
	assertPanicsWith(t, "follows an optional", func() {
		NewSchema(Op("a", "", KindString, Opt("x", KindString, ""), P("y", KindString, "")))
	})
}

func TestSignature(t *testing.T) {
	s := NewSchema(
		Op("add", "", KindInt, P("text", KindString, ""), Opt("urgent", KindBool, "")),
		Op("list", "", KindString),
	)
	if got := s.Signature("add"); got != "add(text:string, urgent:bool?) -> int" {
		t.Errorf("got %q", got)
	}
	if got := s.Signature("list"); got != "list() -> string" {
		t.Errorf("got %q", got)
	}
	if s.Signature("nope") != "" {
		t.Error("an undeclared verb has no signature")
	}
}

func TestSchemaJSON(t *testing.T) {
	s := NewSchema(Op("add", `say "hi"`, KindInt, P("text", KindString, "what")))
	got := s.JSON()
	for _, want := range []string{
		`"name":"add"`, `"result":"int"`, `"kind":"string"`, `"optional":false`,
		`say \"hi\"`,
	} {
		if !strings.Contains(got, want) {
			t.Errorf("expected %s in:\n%s", want, got)
		}
	}
	if NewSchema().JSON() != `{"verbs":[]}` {
		t.Errorf("empty schema: %s", NewSchema().JSON())
	}
}

func TestDiffAllowsAdditiveChanges(t *testing.T) {
	old := NewSchema(Op("add", "", KindInt, P("text", KindString, "")))
	next := NewSchema(
		Op("add", "better docs", KindInt, P("text", KindString, ""),
			Opt("urgent", KindBool, "")), // appended optional
		Op("count", "", KindInt), // whole new verb
	)
	if breaks := next.Diff(old); len(breaks) != 0 {
		t.Errorf("expected an additive upgrade to be clean, got %v", breaks)
	}
}

func TestDiffCatchesBreakingChanges(t *testing.T) {
	old := NewSchema(
		Op("add", "", KindInt, P("text", KindString, "")),
		Op("list", "", KindString),
	)
	cases := []struct {
		name string
		next *Schema
		want string
	}{
		{"verb removed", NewSchema(Op("add", "", KindInt, P("text", KindString, ""))),
			"verb list removed"},
		{"param removed", NewSchema(Op("add", "", KindInt), Op("list", "", KindString)),
			"parameter text removed"},
		{"kind changed", NewSchema(
			Op("add", "", KindInt, P("text", KindInt, "")), Op("list", "", KindString)),
			"changed from string to int"},
		{"param renamed", NewSchema(
			Op("add", "", KindInt, P("body", KindString, "")), Op("list", "", KindString)),
			"renamed from text to body"},
		{"required added", NewSchema(
			Op("add", "", KindInt, P("text", KindString, ""), P("who", KindString, "")),
			Op("list", "", KindString)),
			"required parameter who added"},
		{"result changed", NewSchema(
			Op("add", "", KindString, P("text", KindString, "")), Op("list", "", KindString)),
			"result changed from int to string"},
		{"became required", NewSchema(
			Op("add", "", KindInt, P("text", KindString, "")),
			Op("list", "", KindString, P("filter", KindString, ""))),
			"required parameter filter added"},
	}
	for _, c := range cases {
		breaks := c.next.Diff(old)
		if len(breaks) == 0 {
			t.Errorf("%s: expected a breaking change, got none", c.name)
			continue
		}
		if !strings.Contains(strings.Join(breaks, "; "), c.want) {
			t.Errorf("%s: expected %q, got %v", c.name, c.want, breaks)
		}
	}
}

func TestDiffAgainstNothing(t *testing.T) {
	s := NewSchema(Op("a", "", KindString))
	if breaks := s.Diff(nil); len(breaks) != 0 {
		t.Errorf("the first handler breaks nothing, got %v", breaks)
	}
}

func assertPanicsWith(t *testing.T, substr string, fn func()) {
	t.Helper()
	defer func() {
		r := recover()
		if r == nil {
			t.Errorf("expected a panic containing %q, got none", substr)
			return
		}
		err, ok := r.(error)
		if !ok {
			t.Errorf("expected an error panic, got %v", r)
			return
		}
		if !strings.Contains(err.Error(), substr) {
			t.Errorf("expected a panic containing %q, got %q", substr, err.Error())
		}
	}()
	fn()
}
