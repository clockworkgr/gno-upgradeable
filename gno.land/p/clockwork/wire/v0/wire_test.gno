package wire

import "testing"

const addr = address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5")

func TestRoundTripAllTypes(t *testing.T) {
	payload := NewWriter().
		Bool(true).
		Byte(0xAB).
		Uint(1<<63 + 7).
		Int(-42).
		Uvarint(300).
		Varint(-1000000).
		Str("buy milk, eggs\nand \"bread\"").
		Blob([]byte{0, 1, 2, 255}).
		Addr(addr).
		Bytes()

	r := NewReader(payload)
	if !r.Bool() {
		t.Error("bool")
	}
	if r.Byte() != 0xAB {
		t.Error("byte")
	}
	if r.Uint() != 1<<63+7 {
		t.Error("uint")
	}
	if r.Int() != -42 {
		t.Error("int")
	}
	if r.Uvarint() != 300 {
		t.Error("uvarint")
	}
	if r.Varint() != -1000000 {
		t.Error("varint")
	}
	if r.Str() != "buy milk, eggs\nand \"bread\"" {
		t.Error("str: delimiters/quotes/newlines must survive")
	}
	blob := r.Blob()
	if len(blob) != 4 || blob[3] != 255 {
		t.Error("blob")
	}
	if r.Addr() != addr {
		t.Error("addr")
	}
	if err := r.Err(); err != nil {
		t.Errorf("unexpected error: %v", err)
	}
	if !r.Done() {
		t.Errorf("expected all %d bytes consumed, %d remain", len(payload), r.Remaining())
	}
}

// The reason for a length-prefixed format: values containing separators,
// quotes and newlines round-trip untouched, unlike CSV which must quote them.
func TestStringsWithAnyBytes(t *testing.T) {
	cases := []string{"", "a,b,c", "\"quoted\"", "line1\nline2", "\x00\x01\xff"}
	for _, s := range cases {
		r := NewReader(NewWriter().Str(s).Bytes())
		if got := r.Str(); got != s {
			t.Errorf("round trip %q -> %q", s, got)
		}
		if !r.Done() {
			t.Errorf("%q: not fully consumed", s)
		}
	}
}

func TestVarintZigzag(t *testing.T) {
	for _, v := range []int64{0, 1, -1, 63, -64, 1 << 40, -(1 << 40), 1<<63 - 1, -1 << 63} {
		r := NewReader(NewWriter().Varint(v).Bytes())
		if got := r.Varint(); got != v {
			t.Errorf("varint %d -> %d", v, got)
		}
	}
}

func TestUvarintWidths(t *testing.T) {
	// 1 byte below 128, 2 bytes at 128, and the largest value.
	if l := NewWriter().Uvarint(127).Len(); l != 1 {
		t.Errorf("127 should take 1 byte, took %d", l)
	}
	if l := NewWriter().Uvarint(128).Len(); l != 2 {
		t.Errorf("128 should take 2 bytes, took %d", l)
	}
	r := NewReader(NewWriter().Uvarint(1<<64 - 1).Bytes())
	if r.Uvarint() != 1<<64-1 {
		t.Error("max uint64 round trip")
	}
}

// Optional trailing fields: a reader stops at the end and reports it via More,
// so a v2 payload that appended a field is readable and a v1 one is too.
func TestOptionalTrailingFields(t *testing.T) {
	// v1 payload: just a required id.
	v1 := NewWriter().Int(7).Bytes()
	// v2 payload: id plus an optional flag.
	v2 := NewWriter().Int(7).Bool(true).Bytes()

	read := func(b []byte) (int64, bool) {
		r := NewReader(b)
		id := r.Int()
		flag := false
		if r.More() {
			flag = r.Bool()
		}
		if r.Err() != nil {
			t.Fatal(r.Err())
		}
		return id, flag
	}
	if id, flag := read(v1); id != 7 || flag {
		t.Errorf("v1: got %d,%v", id, flag)
	}
	if id, flag := read(v2); id != 7 || !flag {
		t.Errorf("v2: got %d,%v", id, flag)
	}
}

// A truncated payload must fail cleanly, not panic, and zero-value the reads
// past the end.
func TestTruncationIsSafe(t *testing.T) {
	full := NewWriter().Int(1).Str("hello").Int(2).Bytes()
	for cut := 0; cut < len(full); cut++ {
		r := NewReader(full[:cut])
		// read the full schema regardless; must never panic
		_ = r.Int()
		_ = r.Str()
		_ = r.Int()
		if r.Err() == nil && !r.Done() {
			t.Errorf("cut %d: expected error or clean finish", cut)
		}
	}
}

// A hostile payload claiming a huge string length must be refused, not used to
// slice out of bounds.
func TestHostileLengthRefused(t *testing.T) {
	// Uvarint length 1e9, then no data.
	w := NewWriter().Uvarint(1000000000)
	r := NewReader(w.Bytes())
	if got := r.Str(); got != "" {
		t.Errorf("expected empty on overlong length, got %q", got)
	}
	if r.Err() != ErrShort {
		t.Errorf("expected ErrShort, got %v", r.Err())
	}
}

func TestUvarintOverflowRefused(t *testing.T) {
	// 11 continuation bytes: overflows uint64.
	bad := []byte{0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01}
	r := NewReader(bad)
	if r.Uvarint() != 0 || r.Err() != ErrOverflow {
		t.Errorf("expected ErrOverflow, got err=%v", r.Err())
	}
}

// Once the sticky error is set, later reads are inert and keep the first error.
func TestStickyError(t *testing.T) {
	r := NewReader([]byte{}) // empty
	_ = r.Int()              // fails: ErrShort
	first := r.Err()
	_ = r.Str() // inert
	_ = r.Bool()
	if r.Err() != first || first != ErrShort {
		t.Errorf("sticky error changed: %v", r.Err())
	}
}

func TestWriterReset(t *testing.T) {
	w := NewWriter().Int(1).Str("x")
	w.Reset()
	if w.Len() != 0 {
		t.Error("reset should empty the buffer")
	}
	r := NewReader(w.Int(9).Bytes())
	if r.Int() != 9 || !r.Done() {
		t.Error("writer unusable after reset")
	}
}
