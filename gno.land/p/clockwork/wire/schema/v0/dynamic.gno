package schema

import (
	"errors"

	"gno.land/p/clockwork/wire/v0"
)

// Encode and Decode are the reflection-free runtime codec: they walk a
// schema's fields in the same sorted order the generated code does, so a
// value encoded dynamically and one encoded by generated code are byte for
// byte identical. Use them for generic tooling, or when you would rather carry
// a schema than generate code.
//
// A message value is a map of field name to Go value; the Go type expected for
// each kind is:
//
//	bool -> bool, byte -> byte, int/varint -> int64, uint/uvarint -> uint64,
//	string -> string, bytes -> []byte, address -> address,
//	[]T -> []any, message -> map[string]any

// Encode serializes v against the named message. Every field the message
// declares must be present in v, with the Go type its kind expects.
func (s *Schema) Encode(msg string, v map[string]any) ([]byte, error) {
	w := wire.NewWriter()
	if err := s.encodeMsg(w, msg, v); err != nil {
		return nil, err
	}
	return w.Bytes(), nil
}

// Decode parses b into a value for the named message.
func (s *Schema) Decode(msg string, b []byte) (map[string]any, error) {
	r := wire.NewReader(b)
	v := s.decodeMsg(r, msg)
	if r.Err() != nil {
		return nil, r.Err()
	}
	if !r.Done() {
		return nil, errors.New("schema: trailing bytes decoding " + q(msg))
	}
	return v, nil
}

func (s *Schema) encodeMsg(w *wire.Writer, name string, v map[string]any) error {
	m, ok := s.Message(name)
	if !ok {
		return errors.New("schema: unknown message " + q(name))
	}
	for _, f := range m.Fields() {
		fv, ok := v[f.Name]
		if !ok {
			return errors.New("schema: " + name + ": missing field " + q(f.Name))
		}
		if err := s.encodeField(w, f, fv); err != nil {
			return err
		}
	}
	return nil
}

func (s *Schema) encodeField(w *wire.Writer, f Field, v any) error {
	bad := func() error {
		return errors.New("schema: field " + q(f.Name) + ": value is not a " + f.TypeExpr())
	}
	switch f.Kind {
	case Bool:
		x, ok := v.(bool)
		if !ok {
			return bad()
		}
		w.Bool(x)
	case Byte:
		x, ok := v.(byte)
		if !ok {
			return bad()
		}
		w.Byte(x)
	case Int:
		x, ok := v.(int64)
		if !ok {
			return bad()
		}
		w.Int(x)
	case Varint:
		x, ok := v.(int64)
		if !ok {
			return bad()
		}
		w.Varint(x)
	case Uint:
		x, ok := v.(uint64)
		if !ok {
			return bad()
		}
		w.Uint(x)
	case Uvarint:
		x, ok := v.(uint64)
		if !ok {
			return bad()
		}
		w.Uvarint(x)
	case String:
		x, ok := v.(string)
		if !ok {
			return bad()
		}
		w.Str(x)
	case Bytes:
		x, ok := v.([]byte)
		if !ok {
			return bad()
		}
		w.Blob(x)
	case Address:
		x, ok := v.(address)
		if !ok {
			return bad()
		}
		w.Addr(x)
	case Msg:
		x, ok := v.(map[string]any)
		if !ok {
			return bad()
		}
		return s.encodeMsg(w, f.Ref, x)
	case List:
		x, ok := v.([]any)
		if !ok {
			return bad()
		}
		w.Uvarint(uint64(len(x)))
		elem := Field{Name: f.Name, Kind: f.Elem, Ref: f.Ref}
		for _, e := range x {
			if err := s.encodeField(w, elem, e); err != nil {
				return err
			}
		}
	default:
		return bad()
	}
	return nil
}

func (s *Schema) decodeMsg(r *wire.Reader, name string) map[string]any {
	m, ok := s.Message(name)
	if !ok {
		return nil
	}
	out := map[string]any{}
	for _, f := range m.Fields() {
		out[f.Name] = s.decodeField(r, f)
	}
	return out
}

func (s *Schema) decodeField(r *wire.Reader, f Field) any {
	switch f.Kind {
	case Bool:
		return r.Bool()
	case Byte:
		return r.Byte()
	case Int:
		return r.Int()
	case Varint:
		return r.Varint()
	case Uint:
		return r.Uint()
	case Uvarint:
		return r.Uvarint()
	case String:
		return r.Str()
	case Bytes:
		return r.Blob()
	case Address:
		return r.Addr()
	case Msg:
		return s.decodeMsg(r, f.Ref)
	case List:
		n := r.Uvarint()
		c := n
		if c > uint64(r.Remaining()) {
			c = uint64(r.Remaining())
		}
		out := make([]any, 0, c)
		elem := Field{Name: f.Name, Kind: f.Elem, Ref: f.Ref}
		for k := uint64(0); k < n; k++ {
			if r.Err() != nil {
				break
			}
			out = append(out, s.decodeField(r, elem))
		}
		return out
	}
	return nil
}
