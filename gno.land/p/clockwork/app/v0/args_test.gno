package app

import (
	"strings"
	"testing"
)

var (
	vAdd      = Op("add", "", KindInt, P("text", KindString, ""))
	vTransfer = Op("transfer", "", KindString,
		P("to", KindAddress, ""), P("amount", KindInt, ""), Opt("memo", KindString, ""))
	vNone = Op("ping", "", KindString)
)

const someAddr = "g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5"

// The reason the wire format is CSV rather than a split on commas.
func TestRoundTripSurvivesSeparatorsInValues(t *testing.T) {
	for _, text := range []string{
		"buy milk",
		"buy milk, eggs, bread",
		`she said "hello"`,
		"a\nb",
		"",
	} {
		args, err := decode(vAdd, Encode(vAdd, text))
		if err != nil {
			t.Errorf("%q: %v", text, err)
			continue
		}
		if got := args.String("text"); got != text {
			t.Errorf("round trip: sent %q, got %q", text, got)
		}
	}
}

func TestDecodeChecksArity(t *testing.T) {
	if _, err := decode(vTransfer, Encode(vTransfer, someAddr, "42")); err != nil {
		t.Errorf("omitting an optional should be fine: %v", err)
	}
	if _, err := decode(vTransfer, someAddr); err == nil {
		t.Error("a missing required parameter should be refused")
	} else if !strings.Contains(err.Error(), "needs at least 2") {
		t.Errorf("unhelpful error: %v", err)
	}
	if _, err := decode(vTransfer, someAddr+",42,memo,extra"); err == nil {
		t.Error("too many fields should be refused")
	}
	if _, err := decode(vNone, ""); err != nil {
		t.Errorf("a verb with no parameters takes an empty payload: %v", err)
	}
	if _, err := decode(vNone, "surprise"); err == nil {
		t.Error("a verb with no parameters should refuse a payload")
	}
}

// The point of declaring kinds: a bad value is refused before the handler
// runs, with a message naming the parameter.
func TestDecodeChecksKinds(t *testing.T) {
	_, err := decode(vTransfer, "not-an-address,42")
	if err == nil || !strings.Contains(err.Error(), "parameter to") {
		t.Errorf("expected a complaint about 'to', got %v", err)
	}
	_, err = decode(vTransfer, someAddr+",lots")
	if err == nil || !strings.Contains(err.Error(), "parameter amount") {
		t.Errorf("expected a complaint about 'amount', got %v", err)
	}
	if err != nil && !strings.Contains(err.Error(), "signature is") {
		t.Errorf("the error should show the signature, got %v", err)
	}
}

func TestArgsAccessors(t *testing.T) {
	args, err := decode(vTransfer, Encode(vTransfer, someAddr, "42", "rent"))
	if err != nil {
		t.Fatal(err)
	}
	if args.Verb() != "transfer" {
		t.Errorf("Verb() = %q", args.Verb())
	}
	if args.Address("to") != address(someAddr) {
		t.Errorf("to = %q", args.Address("to"))
	}
	if args.Int("amount") != 42 {
		t.Errorf("amount = %d", args.Int("amount"))
	}
	if args.String("memo") != "rent" || !args.Has("memo") {
		t.Errorf("memo = %q", args.String("memo"))
	}
	if len(args.Raw()) != 3 {
		t.Errorf("Raw() = %v", args.Raw())
	}
}

func TestArgsOmittedOptionalReadsZero(t *testing.T) {
	args, err := decode(vTransfer, Encode(vTransfer, someAddr, "42"))
	if err != nil {
		t.Fatal(err)
	}
	if args.Has("memo") {
		t.Error("memo was not supplied")
	}
	if args.String("memo") != "" {
		t.Errorf("an omitted optional should read empty, got %q", args.String("memo"))
	}
}

// Reading a parameter that was never declared, or reading it as the wrong
// kind, is a bug in the handler that no payload can fix — so it panics rather
// than returning a zero value that would be silently wrong.
func TestArgsAccessorsPanicOnHandlerMistakes(t *testing.T) {
	args, _ := decode(vAdd, Encode(vAdd, "hi"))
	assertPanicsWith(t, "has no parameter nope", func() { args.String("nope") })
	assertPanicsWith(t, "is declared string, read as int", func() { args.Int("text") })
}

// Encoding is validated too, so a realm calling another app fails where the
// mistake was made rather than in someone else's realm.
func TestEncodeValidates(t *testing.T) {
	assertPanicsWith(t, "expected an integer", func() { Encode(vTransfer, someAddr, "lots") })
	assertPanicsWith(t, "needs at least 2", func() { Encode(vTransfer, someAddr) })
	assertPanicsWith(t, "takes at most 3", func() {
		Encode(vTransfer, someAddr, "1", "m", "extra")
	})
}
