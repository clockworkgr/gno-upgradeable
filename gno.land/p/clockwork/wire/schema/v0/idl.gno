package schema

import (
	"errors"
	"strconv"
	"strings"
)

// The IDL is a minimal, language-neutral text form of a schema — the file you
// check in and hand to a generator in any language:
//
//	message Transfer {
//	  amount int
//	  memo   string
//	  to     address
//	}
//
//	message Order {
//	  buyer address
//	  id    uint
//	  items []Item
//	  tags  []string
//	}
//
// A field is `name type`; a type is a scalar keyword (bool, byte, int, uint,
// varint, uvarint, string, bytes, address), a message name, `[]scalar`, or
// `[]MessageName`. There are no field numbers. Declaration order is ignored:
// [Schema.String] always prints fields sorted, which is the serialization
// order too, so the printed form is canonical.

// Parse reads the IDL. The result is not validated; call [Schema.Validate].
func Parse(src string) (*Schema, error) {
	var msgs []*Message
	var cur *Message
	lines := strings.Split(src, "\n")
	for i, raw := range lines {
		line := raw
		if c := strings.Index(line, "//"); c >= 0 {
			line = line[:c]
		}
		toks := strings.Fields(line)
		if len(toks) == 0 {
			continue
		}
		where := " (line " + strconv.Itoa(i+1) + ")"

		if cur == nil {
			if toks[0] != "message" || len(toks) != 3 || toks[2] != "{" {
				return nil, errors.New("schema: expected `message Name {`" + where)
			}
			cur = &Message{Name: toks[1]}
			continue
		}

		if toks[0] == "}" {
			if len(toks) != 1 {
				return nil, errors.New("schema: trailing tokens after `}`" + where)
			}
			msgs = append(msgs, cur)
			cur = nil
			continue
		}

		if len(toks) != 2 {
			return nil, errors.New("schema: expected `name type`" + where)
		}
		f, err := parseField(toks[0], toks[1])
		if err != nil {
			return nil, errors.New(err.Error() + where)
		}
		cur.fields = append(cur.fields, f)
	}
	if cur != nil {
		return nil, errors.New("schema: unterminated message " + q(cur.Name))
	}
	return New(msgs...), nil
}

func parseField(name, typ string) (Field, error) {
	if strings.HasPrefix(typ, "[]") {
		elem := typ[2:]
		if k := kindFromKeyword(elem); k != Invalid {
			return ListOf(name, k), nil
		}
		if !isIdent(elem) {
			return Field{}, errors.New("schema: bad list element type " + q(elem))
		}
		return ListOfNested(name, elem), nil
	}
	if k := kindFromKeyword(typ); k != Invalid {
		return Scalar(name, k), nil
	}
	if !isIdent(typ) {
		return Field{}, errors.New("schema: bad type " + q(typ))
	}
	return Nested(name, typ), nil // a message reference, resolved by Validate
}

// String renders the schema as canonical IDL: messages in definition order,
// fields sorted, names aligned. Parsing the result yields an equivalent
// schema.
func (s *Schema) String() string {
	var b strings.Builder
	for i, m := range s.Messages() {
		if i > 0 {
			b.WriteString("\n")
		}
		b.WriteString("message " + m.Name + " {\n")
		fields := m.Fields()
		width := 0
		for _, f := range fields {
			if len(f.Name) > width {
				width = len(f.Name)
			}
		}
		for _, f := range fields {
			b.WriteString("  " + f.Name)
			for p := len(f.Name); p < width; p++ {
				b.WriteString(" ")
			}
			b.WriteString(" " + f.TypeExpr() + "\n")
		}
		b.WriteString("}\n")
	}
	return b.String()
}
