package wire

import "testing"

// Regression: a string whose length prefix is 2^63-1 with no data behind it.
// The bounds check must compare against the bytes remaining, not r.off+n,
// which would overflow int64 and let the slice panic. The package promises
// never to panic on hostile input.
func TestHostileHugeLengthMustNotPanic(t *testing.T) {
	payload := NewWriter().Uvarint(1<<63 - 1).Bytes() // length prefix only, no data
	r := NewReader(payload)
	got := r.Str() // must return "" + ErrShort, not panic
	if got != "" {
		t.Errorf("expected empty, got %d bytes", len(got))
	}
	if r.Err() != ErrShort {
		t.Errorf("expected ErrShort, got %v", r.Err())
	}
}

func TestHostileHugeLengthBlobMidPayload(t *testing.T) {
	// a valid int first (so r.off>0), then a blob claiming 2^63-1 bytes
	payload := NewWriter().Int(7).Uvarint(1<<63 - 1).Bytes()
	r := NewReader(payload)
	if r.Int() != 7 {
		t.Fatal("int")
	}
	if b := r.Blob(); b != nil {
		t.Errorf("expected nil blob, got %d bytes", len(b))
	}
	if r.Err() != ErrShort {
		t.Errorf("expected ErrShort, got %v", r.Err())
	}
}

// A length in [2^63, 2^64) whose int() conversion is negative must also be
// caught (by the n<0 arm), not slice with a negative length.
func TestHostileNegativeLength(t *testing.T) {
	payload := NewWriter().Uvarint(1<<63 + 5).Bytes()
	r := NewReader(payload)
	if r.Str() != "" {
		t.Error("expected empty")
	}
	if r.Err() != ErrShort {
		t.Errorf("expected ErrShort, got %v", r.Err())
	}
}
