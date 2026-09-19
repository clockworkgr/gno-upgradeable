package app

import (
	"encoding/csv"
	"errors"
	"strconv"
	"strings"
	"unicode/utf8"
)

// The wire format is one CSV record.
//
// CSV because it is in the standard library, because it quotes correctly --
// a task called `buy milk, eggs` survives a round trip, which a naive split
// on commas does not -- and because it is writable by hand on a gnokey
// command line. Fields are positional, in the order the verb declares them,
// which is why the schema forbids a required parameter after an optional one
// and why Diff treats a reordering as breaking.
//
//	Encode(addTask, "buy milk, eggs")  ->  "buy milk, eggs"   (quoted by csv)
//	Encode(transfer, "g1abc…", "42")   ->  "g1abc…,42"
//
// A verb with no parameters takes an empty payload.

// Args is a decoded, validated payload. A handler receives one and reads
// fields by name; the app has already checked that every field is present and
// parses as its declared kind, so the accessors do not return errors.
type Args struct {
	verb   Verb
	values []string
}

// Verb returns the name of the verb being called.
func (a *Args) Verb() string { return a.verb.Name }

// Signature returns the declaration this payload was checked against, which
// is worth putting in a panic message.
func (a *Args) Signature() string { return a.verb.Signature() }

// Raw returns the decoded fields in declaration order, for a handler that
// would rather loop than name them.
func (a *Args) Raw() []string {
	dup := make([]string, len(a.values))
	copy(dup, a.values)
	return dup
}

// index returns the position of name and whether a value was supplied.
// It panics if the verb has no such parameter: that is the handler asking for
// something it did not declare, which no payload can fix.
func (a *Args) index(name string, want Kind) (int, bool) {
	for i, p := range a.verb.Params {
		if p.Name != name {
			continue
		}
		if want != "" && p.Kind != want {
			panic(errors.New("app: " + a.verb.Name + ": parameter " + name +
				" is declared " + string(p.Kind) + ", read as " + string(want)))
		}
		return i, i < len(a.values)
	}
	panic(errors.New("app: " + a.verb.Name + " has no parameter " + name +
		"; its signature is " + a.verb.Signature()))
}

// Has reports whether an optional parameter was supplied.
func (a *Args) Has(name string) bool {
	_, ok := a.index(name, "")
	return ok
}

// String returns a string parameter, or "" if it was optional and omitted.
func (a *Args) String(name string) string {
	i, ok := a.index(name, KindString)
	if !ok {
		return ""
	}
	return a.values[i]
}

// Int returns an int parameter, or 0 if it was optional and omitted.
func (a *Args) Int(name string) int64 {
	i, ok := a.index(name, KindInt)
	if !ok {
		return 0
	}
	n, _ := strconv.ParseInt(a.values[i], 10, 64) // checked at decode
	return n
}

// Bool returns a bool parameter, or false if it was optional and omitted.
func (a *Args) Bool(name string) bool {
	i, ok := a.index(name, KindBool)
	if !ok {
		return false
	}
	return a.values[i] == "true"
}

// Address returns an address parameter, or the zero address if it was
// optional and omitted.
func (a *Args) Address(name string) address {
	i, ok := a.index(name, KindAddress)
	if !ok {
		return ""
	}
	return address(a.values[i])
}

// Encode builds a payload for v from values given in declaration order,
// validating each against its declared kind. Use it when one realm calls
// another app, so an encoding mistake fails where it was made.
func Encode(v Verb, values ...string) string {
	if err := checkArity(v, len(values)); err != nil {
		panic(err)
	}
	for i, val := range values {
		if err := v.Params[i].Kind.parse(val); err != nil {
			panic(fieldErr(v, i, err))
		}
	}
	if len(values) == 0 {
		return ""
	}
	// A lone empty field encodes to nothing at all -- csv does not quote an
	// empty field, so the record "" and the record with no fields are the
	// same bytes. Quote it explicitly so the payload says which it is.
	if len(values) == 1 && values[0] == "" {
		return `""`
	}
	// Fast path: when nothing needs quoting, a CSV record IS the fields
	// joined by commas, and building a csv.Writer to discover that costs
	// more than the whole rest of the call. See needsQuotes.
	plain := true
	for _, val := range values {
		if needsQuotes(val) {
			plain = false
			break
		}
	}
	if plain {
		return strings.Join(values, ",")
	}

	var b strings.Builder
	w := csv.NewWriter(&b)
	if err := w.Write(values); err != nil {
		panic(errors.New("app: " + v.Name + ": " + err.Error()))
	}
	w.Flush()
	if err := w.Error(); err != nil {
		panic(errors.New("app: " + v.Name + ": " + err.Error()))
	}
	return strings.TrimRight(b.String(), "\n")
}

// splitPlain splits a payload on commas in a single pass, reporting false the
// moment it meets a byte that gives commas a different meaning. The one pass
// is the point: bailing out and splitting separately doubles the interpreted
// work over the whole payload.
func splitPlain(payload string) ([]string, bool) {
	out := []string{}
	start := 0
	for i := 0; i < len(payload); i++ {
		switch payload[i] {
		case '"', '\r', '\n':
			return nil, false
		case ',':
			out = append(out, payload[start:i])
			start = i + 1
		}
	}
	return append(out, payload[start:]), true
}

// needsQuotes mirrors csv.Writer's rule exactly. Diverging from it would mean
// Encode produced something csv.Reader reads back differently, so this is
// copied rather than approximated: a field is quoted when it is the literal
// `\.`, when it contains a comma, quote, CR or LF, or when it begins with a
// space.
func needsQuotes(field string) bool {
	if field == "" {
		return false
	}
	if field == `\.` {
		return true
	}
	switch field[0] {
	case ' ', '\t', '\v', '\f':
		return true
	}
	// A leading non-ASCII space (U+00A0 and friends) is rare enough to hand
	// to the slow path rather than decode a rune for on every call.
	if field[0] >= utf8.RuneSelf {
		return true
	}
	// One pass, for the same reason splitPlain is one pass:
	// strings.ContainsAny is interpreted Gno and costs more over a short
	// field than the csv.Writer it is trying to avoid.
	for i := 0; i < len(field); i++ {
		switch field[i] {
		case ',', '"', '\r', '\n':
			return true
		}
	}
	return false
}

// checkArity reports whether n values can satisfy v.
func checkArity(v Verb, n int) error {
	req := v.Required()
	if n < req {
		return errors.New("app: " + v.Name + " needs at least " + strconv.Itoa(req) +
			" parameter(s), got " + strconv.Itoa(n) + "; signature is " + v.Signature())
	}
	if n > len(v.Params) {
		return errors.New("app: " + v.Name + " takes at most " + strconv.Itoa(len(v.Params)) +
			" parameter(s), got " + strconv.Itoa(n) + "; signature is " + v.Signature())
	}
	return nil
}

// fieldErr names the verb, the parameter and the signature, which is what a
// caller needs to fix the payload without reading the handler's source.
func fieldErr(v Verb, i int, err error) error {
	return errors.New("app: " + v.Name + ": parameter " + v.Params[i].Name +
		": " + err.Error() + "; signature is " + v.Signature())
}

// decode parses and validates a payload against v.
func decode(v Verb, payload string) (*Args, error) {
	values := []string{}
	if payload == "" {
		// Ambiguous on its own: no fields, or one empty field. The verb
		// decides. A required first parameter means an empty payload is that
		// parameter, empty -- which is what a gnokey caller passing "" for a
		// string means, and Encode spells `""` for the same case.
		if v.Required() >= 1 {
			values = []string{""}
		}
	} else if rec, plain := splitPlain(payload); plain {
		// Fast path: with no quote and no newline anywhere, no field is
		// quoted, so every comma is a separator and every field is literal
		// -- exactly what csv.Reader would return. splitPlain decides that
		// and does the split in one pass, because every string operation
		// here is interpreted Gno: two passes with strings.ContainsAny and
		// strings.Split costs more than the csv parse it replaces.
		values = rec
	} else {
		rec, err := csv.NewReader(strings.NewReader(payload)).Read()
		if err != nil {
			return nil, errors.New("app: " + v.Name + ": malformed payload: " + err.Error())
		}
		values = rec
	}
	if err := checkArity(v, len(values)); err != nil {
		return nil, err
	}
	for i, val := range values {
		if err := v.Params[i].Kind.parse(val); err != nil {
			return nil, fieldErr(v, i, err)
		}
	}
	return &Args{verb: v, values: values}, nil
}
