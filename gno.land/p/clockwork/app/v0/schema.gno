package app

import (
	"errors"
	"strconv"
	"strings"
)

// A schema is what a handler says about itself: the verbs it answers, what
// each one takes, and what it gives back. Handlers declare one; the app reads
// it to enumerate the API, to validate payloads before dispatch, and to refuse
// an upgrade that would break a caller.
//
// This is the part a verb-dispatch API is usually missing. Without it, "the
// API" is whatever the live handler's switch statement happens to accept: not
// discoverable, not checkable, and free to change under callers without
// anything noticing. A schema makes it data, which is the same move that makes
// the API growable in the first place.
//
// What it is not is static typing. Gno has no reflection, so nothing here can
// look at your Go types. Validation happens at call time against declarations
// you wrote by hand, and a handler whose switch disagrees with its own schema
// is a bug the schema cannot catch.

// Kind is the type of one payload field. The set is deliberately small: these
// are the types that survive a string encoding without ambiguity.
type Kind string

const (
	KindString  Kind = "string"
	KindInt     Kind = "int"     // int64, base 10
	KindBool    Kind = "bool"    // "true" or "false"
	KindAddress Kind = "address" // bech32, validated
	KindNone    Kind = "none"    // a verb that returns nothing meaningful
)

// Valid reports whether k is a known kind.
func (k Kind) Valid() bool {
	switch k {
	case KindString, KindInt, KindBool, KindAddress, KindNone:
		return true
	}
	return false
}

// parse checks that v is a well-formed value of kind k.
func (k Kind) parse(v string) error {
	switch k {
	case KindString, KindNone:
		return nil
	case KindInt:
		if _, err := strconv.ParseInt(v, 10, 64); err != nil {
			return errors.New("expected an integer, got " + strconv.Quote(v))
		}
	case KindBool:
		if v != "true" && v != "false" {
			return errors.New("expected true or false, got " + strconv.Quote(v))
		}
	case KindAddress:
		if !address(v).IsValid() {
			return errors.New("expected an address, got " + strconv.Quote(v))
		}
	default:
		return errors.New("unknown kind " + string(k))
	}
	return nil
}

// Field is one parameter of a verb.
type Field struct {
	Name string
	Kind Kind
	Doc  string
	Opt  bool // may be omitted, and only at the end of the parameter list
}

// P declares a required parameter.
func P(name string, kind Kind, doc string) Field {
	return Field{Name: name, Kind: kind, Doc: doc}
}

// Opt declares an optional parameter. Optional parameters must come last, and
// appending one is the only way to add a parameter to a verb without breaking
// callers.
func Opt(name string, kind Kind, doc string) Field {
	return Field{Name: name, Kind: kind, Doc: doc, Opt: true}
}

// Verb is one operation's signature.
type Verb struct {
	Name   string
	Doc    string
	Result Kind
	Params []Field
}

// Op declares a verb.
func Op(name, doc string, result Kind, params ...Field) Verb {
	return Verb{Name: name, Doc: doc, Result: result, Params: params}
}

// Required returns how many leading parameters must be supplied.
func (v Verb) Required() int {
	n := 0
	for _, p := range v.Params {
		if p.Opt {
			break
		}
		n++
	}
	return n
}

// Signature renders the verb as a one-line declaration:
//
//	add(text:string, urgent:bool?) -> int
func (v Verb) Signature() string {
	var b strings.Builder
	b.WriteString(v.Name)
	b.WriteString("(")
	for i, p := range v.Params {
		if i > 0 {
			b.WriteString(", ")
		}
		b.WriteString(p.Name + ":" + string(p.Kind))
		if p.Opt {
			b.WriteString("?")
		}
	}
	b.WriteString(") -> " + string(v.Result))
	return b.String()
}

// Schema is a handler's whole API, sorted by verb name.
type Schema struct {
	verbs []Verb
}

// NewSchema validates and sorts the declarations. It panics on a schema that
// could not be served correctly: a blank or duplicate name, an unknown kind, a
// required parameter after an optional one, or a duplicate parameter name.
// Those are all authoring mistakes, and a handler carrying one should fail to
// deploy rather than mis-describe itself forever.
func NewSchema(verbs ...Verb) *Schema {
	s := &Schema{verbs: make([]Verb, 0, len(verbs))}
	for _, v := range verbs {
		if strings.TrimSpace(v.Name) == "" || v.Name != strings.TrimSpace(v.Name) {
			panic(errors.New("app: verb names must be non-blank and unpadded"))
		}
		if !v.Result.Valid() {
			panic(errors.New("app: verb " + v.Name + ": unknown result kind " + string(v.Result)))
		}
		if _, dup := s.Lookup(v.Name); dup {
			panic(errors.New("app: duplicate verb " + v.Name))
		}
		seenOpt := false
		for i, p := range v.Params {
			if strings.TrimSpace(p.Name) == "" || p.Name != strings.TrimSpace(p.Name) {
				panic(errors.New("app: verb " + v.Name + ": parameter names must be non-blank and unpadded"))
			}
			if !p.Kind.Valid() || p.Kind == KindNone {
				panic(errors.New("app: verb " + v.Name + ": parameter " + p.Name +
					" has unusable kind " + string(p.Kind)))
			}
			if p.Opt {
				seenOpt = true
			} else if seenOpt {
				// The encoding is positional, so a required parameter after an
				// optional one could never be supplied without the optional.
				panic(errors.New("app: verb " + v.Name + ": required parameter " +
					p.Name + " follows an optional one"))
			}
			for j := 0; j < i; j++ {
				if v.Params[j].Name == p.Name {
					panic(errors.New("app: verb " + v.Name + ": duplicate parameter " + p.Name))
				}
			}
		}
		at := len(s.verbs)
		for i, e := range s.verbs {
			if v.Name < e.Name {
				at = i
				break
			}
		}
		s.verbs = append(s.verbs, Verb{})
		copy(s.verbs[at+1:], s.verbs[at:])
		s.verbs[at] = v
	}
	return s
}

// Names returns the verb names, sorted.
func (s *Schema) Names() []string {
	if s == nil {
		return nil
	}
	out := make([]string, 0, len(s.verbs))
	for _, v := range s.verbs {
		out = append(out, v.Name)
	}
	return out
}

// Lookup returns the verb by name.
func (s *Schema) Lookup(name string) (Verb, bool) {
	if s == nil {
		return Verb{}, false
	}
	for _, v := range s.verbs {
		if v.Name == name {
			return v, true
		}
	}
	return Verb{}, false
}

// Verbs returns a copy of the declarations.
func (s *Schema) Verbs() []Verb {
	if s == nil {
		return nil
	}
	dup := make([]Verb, len(s.verbs))
	copy(dup, s.verbs)
	return dup
}

// Signature renders one verb, or "" if it is not declared.
func (s *Schema) Signature(name string) string {
	if v, ok := s.Lookup(name); ok {
		return v.Signature()
	}
	return ""
}

// Markdown renders the API as a table, for Render.
func (s *Schema) Markdown() string {
	if s == nil || len(s.verbs) == 0 {
		return "_No API declared._\n"
	}
	var b strings.Builder
	b.WriteString("| Verb | Payload | Returns | |\n|---|---|---|---|\n")
	for _, v := range s.verbs {
		params := make([]string, 0, len(v.Params))
		for _, p := range v.Params {
			f := p.Name + ":" + string(p.Kind)
			if p.Opt {
				f += "?"
			}
			params = append(params, f)
		}
		p := strings.Join(params, ", ")
		if p == "" {
			p = "—"
		}
		b.WriteString("| `" + v.Name + "` | `" + p + "` | `" + string(v.Result) +
			"` | " + v.Doc + " |\n")
	}
	return b.String()
}

// JSON renders the schema for tooling: a client can build a form from this
// without reading any Gno source.
func (s *Schema) JSON() string {
	var b strings.Builder
	b.WriteString(`{"verbs":[`)
	if s != nil {
		for i, v := range s.verbs {
			if i > 0 {
				b.WriteString(",")
			}
			b.WriteString(`{"name":` + jsonStr(v.Name) +
				`,"doc":` + jsonStr(v.Doc) +
				`,"result":` + jsonStr(string(v.Result)) +
				`,"params":[`)
			for j, p := range v.Params {
				if j > 0 {
					b.WriteString(",")
				}
				b.WriteString(`{"name":` + jsonStr(p.Name) +
					`,"kind":` + jsonStr(string(p.Kind)) +
					`,"doc":` + jsonStr(p.Doc) +
					`,"optional":` + strconv.FormatBool(p.Opt) + `}`)
			}
			b.WriteString(`]}`)
		}
	}
	b.WriteString(`]}`)
	return b.String()
}

// Diff reports what upgrading from prev to s would break for existing callers.
// An empty result means every payload that worked before still works.
//
// Breaking: a verb disappears, a parameter disappears or changes kind or
// position, a new required parameter appears, or a result kind changes.
// Not breaking: a new verb, a new optional parameter at the end, new
// documentation.
func (s *Schema) Diff(prev *Schema) []string {
	out := []string{}
	if prev == nil {
		return out
	}
	for _, old := range prev.verbs {
		nv, ok := s.Lookup(old.Name)
		if !ok {
			out = append(out, "verb "+old.Name+" removed")
			continue
		}
		if nv.Result != old.Result {
			out = append(out, "verb "+old.Name+": result changed from "+
				string(old.Result)+" to "+string(nv.Result))
		}
		for i, op := range old.Params {
			if i >= len(nv.Params) {
				out = append(out, "verb "+old.Name+": parameter "+op.Name+" removed")
				continue
			}
			np := nv.Params[i]
			if np.Name != op.Name {
				out = append(out, "verb "+old.Name+": parameter "+strconv.Itoa(i)+
					" renamed from "+op.Name+" to "+np.Name)
			}
			if np.Kind != op.Kind {
				out = append(out, "verb "+old.Name+": parameter "+op.Name+
					" changed from "+string(op.Kind)+" to "+string(np.Kind))
			}
			if np.Opt != op.Opt && !np.Opt {
				out = append(out, "verb "+old.Name+": parameter "+op.Name+
					" became required")
			}
		}
		for i := len(old.Params); i < len(nv.Params); i++ {
			if !nv.Params[i].Opt {
				out = append(out, "verb "+old.Name+": required parameter "+
					nv.Params[i].Name+" added")
			}
		}
	}
	return out
}

// jsonStr quotes and escapes a string for the JSON rendering above.
func jsonStr(s string) string {
	var b strings.Builder
	b.WriteString(`"`)
	for _, r := range s {
		switch r {
		case '"':
			b.WriteString(`\"`)
		case '\\':
			b.WriteString(`\\`)
		case '\n':
			b.WriteString(`\n`)
		case '\r':
			b.WriteString(`\r`)
		case '\t':
			b.WriteString(`\t`)
		default:
			if r < 0x20 {
				b.WriteString(`\u00`)
				const hex = "0123456789abcdef"
				b.WriteByte(hex[(r>>4)&0xf])
				b.WriteByte(hex[r&0xf])
				continue
			}
			b.WriteRune(r)
		}
	}
	b.WriteString(`"`)
	return b.String()
}
