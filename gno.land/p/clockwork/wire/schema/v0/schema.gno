// Package schema is a tiny, language-neutral schema for the wire codec.
//
// It does not change the wire format — [gno.land/p/clockwork/wire/v0] still
// lays fields out positionally end to end. What the schema adds is agreement:
// it names a message's fields and their types once, in one place, so a gno
// encoder, a TypeScript decoder and a Go client all serialize the same fields
// in the same order without coordinating in code.
//
// # No field numbers
//
// There are no tags or numbers to assign. A message's wire order is simply its
// field names sorted (byte-wise ascending). Two implementations given the same
// set of (name, type) pairs therefore produce identical bytes. Adding a field
// re-sorts the layout, so a schema change is a new message version rather than
// an in-place edit — the same versioning discipline the rest of this
// repository uses. Within a version the shape is fixed.
//
// # What it is for
//
//   - One source of truth. Author a schema once (in Gno, or in the small IDL
//     that [Parse] reads) and generate matching types and marshal/unmarshal
//     code for every language from it (see [Schema.GenerateGno]).
//   - Consistency. The generated and the dynamic ([Schema.Encode]) codecs walk
//     fields in the same sorted order, so they interoperate byte for byte.
//
// The schema is metadata: it never appears on the wire.
package schema

import (
	"errors"
	"strings"
)

// Kind is a field's type.
type Kind uint8

const (
	Invalid Kind = iota
	Bool
	Byte
	Int     // int64, fixed 8 bytes
	Uint    // uint64, fixed 8 bytes
	Varint  // int64, zigzag LEB128
	Uvarint // uint64, LEB128
	String
	Bytes
	Address
	List    // a repeated field; Elem holds the element kind, Ref the message name if Elem==Message
	Msg // a nested message; Ref holds its name
)

var kindNames = map[Kind]string{
	Bool: "bool", Byte: "byte", Int: "int", Uint: "uint",
	Varint: "varint", Uvarint: "uvarint", String: "string",
	Bytes: "bytes", Address: "address",
}

// String returns the IDL keyword for a scalar kind, or "" for List/Message
// (whose spelling depends on Elem/Ref).
func (k Kind) String() string { return kindNames[k] }

func (k Kind) isScalar() bool { return k >= Bool && k <= Address }

// kindFromKeyword maps an IDL scalar keyword to its Kind, or Invalid.
func kindFromKeyword(s string) Kind {
	for k, name := range kindNames {
		if name == s {
			return k
		}
	}
	return Invalid
}

// Field is one field of a message: a name and a type. It carries no number.
type Field struct {
	Name string
	Kind Kind
	Elem Kind   // element kind when Kind == List
	Ref  string // message name when Kind == Message, or when Kind == List && Elem == Message
}

// Scalar builds a scalar field (Bool..Address).
func Scalar(name string, k Kind) Field { return Field{Name: name, Kind: k} }

// ListOf builds a repeated scalar field: []k.
func ListOf(name string, k Kind) Field { return Field{Name: name, Kind: List, Elem: k} }

// Nested builds a field holding another message by name.
func Nested(name, msg string) Field { return Field{Name: name, Kind: Msg, Ref: msg} }

// ListOfNested builds a repeated message field: []msg.
func ListOfNested(name, msg string) Field {
	return Field{Name: name, Kind: List, Elem: Msg, Ref: msg}
}

// TypeExpr renders the field's type as it appears in the IDL: a keyword, a
// message name, "[]keyword", or "[]MessageName".
func (f Field) TypeExpr() string {
	switch f.Kind {
	case Msg:
		return f.Ref
	case List:
		if f.Elem == Msg {
			return "[]" + f.Ref
		}
		return "[]" + f.Elem.String()
	default:
		return f.Kind.String()
	}
}

// Message is a named set of fields. Fields are stored as given but always
// walked in sorted order.
type Message struct {
	Name   string
	fields []Field
}

// NewMessage builds a message from fields given in any order.
func NewMessage(name string, fields ...Field) *Message {
	return &Message{Name: name, fields: fields}
}

// Fields returns the fields in canonical (name-sorted) order — the order they
// are serialized and generated in.
func (m *Message) Fields() []Field {
	out := make([]Field, len(m.fields))
	copy(out, m.fields)
	// insertion sort: field lists are short, and it avoids importing sort.
	for i := 1; i < len(out); i++ {
		f := out[i]
		j := i - 1
		for j >= 0 && out[j].Name > f.Name {
			out[j+1] = out[j]
			j--
		}
		out[j+1] = f
	}
	return out
}

// Schema is a set of messages that may reference one another.
type Schema struct {
	msgs  map[string]*Message
	order []string // message names in the order added, for stable iteration
}

// New builds a schema from messages.
func New(msgs ...*Message) *Schema {
	s := &Schema{msgs: map[string]*Message{}}
	for _, m := range msgs {
		if _, dup := s.msgs[m.Name]; !dup {
			s.order = append(s.order, m.Name)
		}
		s.msgs[m.Name] = m
	}
	return s
}

// Message returns a message by name.
func (s *Schema) Message(name string) (*Message, bool) {
	m, ok := s.msgs[name]
	return m, ok
}

// Messages returns the messages in the order they were added.
func (s *Schema) Messages() []*Message {
	out := make([]*Message, 0, len(s.order))
	for _, n := range s.order {
		out = append(out, s.msgs[n])
	}
	return out
}

// Validate reports the first structural problem: a blank or duplicate name, an
// unknown type keyword, a reference to a message that is not defined, or a
// cycle of nested messages (which a positional, inlined format cannot encode).
func (s *Schema) Validate() error {
	for _, name := range s.order {
		m := s.msgs[name]
		if !isIdent(m.Name) {
			return errors.New("schema: invalid message name " + q(m.Name))
		}
		seen := map[string]bool{}
		for _, f := range m.fields {
			if !isIdent(f.Name) {
				return errors.New("schema: " + m.Name + ": invalid field name " + q(f.Name))
			}
			if seen[f.Name] {
				return errors.New("schema: " + m.Name + ": duplicate field " + q(f.Name))
			}
			seen[f.Name] = true
			if err := s.checkType(m.Name, f); err != nil {
				return err
			}
		}
	}
	return s.checkAcyclic()
}

func (s *Schema) checkType(msg string, f Field) error {
	switch f.Kind {
	case Bool, Byte, Int, Uint, Varint, Uvarint, String, Bytes, Address:
		return nil
	case Msg:
		if _, ok := s.msgs[f.Ref]; !ok {
			return errors.New("schema: " + msg + "." + f.Name + ": unknown message " + q(f.Ref))
		}
		return nil
	case List:
		if f.Elem == Msg {
			if _, ok := s.msgs[f.Ref]; !ok {
				return errors.New("schema: " + msg + "." + f.Name + ": unknown message " + q(f.Ref))
			}
			return nil
		}
		if !f.Elem.isScalar() {
			return errors.New("schema: " + msg + "." + f.Name + ": list of non-scalar")
		}
		return nil
	default:
		return errors.New("schema: " + msg + "." + f.Name + ": invalid kind")
	}
}

// checkAcyclic rejects nested-message cycles by a depth-first walk.
func (s *Schema) checkAcyclic() error {
	state := map[string]int{} // 0 unseen, 1 on-stack, 2 done
	var visit func(name string) error
	visit = func(name string) error {
		switch state[name] {
		case 1:
			return errors.New("schema: cycle through message " + q(name))
		case 2:
			return nil
		}
		state[name] = 1
		m := s.msgs[name]
		if m != nil {
			for _, f := range m.fields {
				// Only direct nesting inlines a message; a list breaks the
				// cycle because it is length-delimited (a message may contain
				// a list of itself).
				if f.Kind == Msg {
					if err := visit(f.Ref); err != nil {
						return err
					}
				}
			}
		}
		state[name] = 2
		return nil
	}
	for _, n := range s.order {
		if err := visit(n); err != nil {
			return err
		}
	}
	return nil
}

// isIdent reports whether s is a non-empty run of ASCII letters, digits and
// underscores that does not start with a digit — a portable identifier.
func isIdent(s string) bool {
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		ok := c == '_' ||
			(c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
			(c >= '0' && c <= '9' && i > 0)
		if !ok {
			return false
		}
	}
	return true
}

func q(s string) string { return "\"" + s + "\"" }

// title upper-cases the first byte, mapping a canonical field or message name
// to an exported Go/Gno identifier. Ordering is always by the canonical name,
// so every language may apply its own casing without disturbing the layout.
func title(s string) string {
	if s == "" {
		return s
	}
	if s[0] >= 'a' && s[0] <= 'z' {
		return string(s[0]-32) + s[1:]
	}
	return s
}

var _ = strings.TrimSpace
