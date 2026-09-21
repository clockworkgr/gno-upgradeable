// Package wire is a schema-positional binary codec for gno.
//
// It exists because gno charges gas per interpreted opcode, and the usual way
// to pack call arguments — a delimited text format like CSV — pays that cost
// per byte: it scans every byte looking for separators and quotes, and parses
// every number with strconv. A format that instead length-prefixes its fields
// lets the reader slice each one out in a fixed number of opcodes, so decoding
// costs on the order of the field count, not the payload length. On measured
// gno, decoding a 60-character string this way is ~30x cheaper than CSV and,
// unlike CSV, does not grow with the string's length.
//
// # The wire has no schema; the call order is the schema
//
// A payload is just values laid end to end. Nothing on the wire says what type
// each one is — the [Reader] must read the same types in the same order the
// [Writer] wrote them. That shared, out-of-band schema is the whole trick: no
// field tags, no type bytes, no delimiters, no quoting.
//
//	// encode (off chain, or in a calling realm)
//	payload := wire.NewWriter().Addr(to).Int(amount).Str(memo).Bytes()
//
//	// decode (in the handler)
//	r := wire.NewReader(payload)
//	to, amount, memo := r.Addr(), r.Int(), r.Str()
//	if err := r.Err(); err != nil {
//		panic(err)
//	}
//
// # Pass it as []byte
//
// Hand the payload to a realm as a []byte argument, not a string. gnokey sends
// a []byte argument base64-encoded and the VM decodes it in native Go before
// your code runs, so the base64 envelope costs no interpreted gas. A string
// argument would arrive raw but forces you back into per-byte parsing.
//
// # Safety
//
// A [Reader] never panics on a malformed or truncated payload, including a
// hostile one that claims a huge length. Every read is bounds-checked; the
// first failure sets a sticky error, every read after it returns a zero value,
// and [Reader.Err] reports it. Check Err once, after reading the fields you
// expect. This makes the codec safe to point at untrusted input.
package wire

import "errors"

var (
	// ErrShort means the payload ended before a value could be read in full,
	// or a length prefix claimed more bytes than remain.
	ErrShort = errors.New("wire: payload too short")

	// ErrOverflow means a varint was longer than a 64-bit value permits.
	ErrOverflow = errors.New("wire: varint overflows 64 bits")
)

// Writer accumulates a binary payload. Its methods append one value each and
// return the Writer, so writes chain. A Writer never fails.
type Writer struct {
	buf []byte
}

// NewWriter returns an empty Writer.
func NewWriter() *Writer { return &Writer{} }

// Bool writes a single 0x00/0x01 byte.
func (w *Writer) Bool(v bool) *Writer {
	if v {
		w.buf = append(w.buf, 1)
	} else {
		w.buf = append(w.buf, 0)
	}
	return w
}

// Byte writes one raw byte.
func (w *Writer) Byte(v byte) *Writer {
	w.buf = append(w.buf, v)
	return w
}

// Uint writes a uint64 as 8 big-endian bytes. Fixed width is the cheapest to
// decode; use Uvarint when values are small and payload size matters more.
func (w *Writer) Uint(v uint64) *Writer {
	w.buf = append(w.buf,
		byte(v>>56), byte(v>>48), byte(v>>40), byte(v>>32),
		byte(v>>24), byte(v>>16), byte(v>>8), byte(v))
	return w
}

// Int writes an int64 as 8 big-endian bytes (two's complement).
func (w *Writer) Int(v int64) *Writer { return w.Uint(uint64(v)) }

// Uvarint writes a uint64 as an unsigned LEB128 varint: 1 byte for values
// below 128, up to 10 for the largest. Compact, slightly dearer to decode.
func (w *Writer) Uvarint(v uint64) *Writer {
	for v >= 0x80 {
		w.buf = append(w.buf, byte(v)|0x80)
		v >>= 7
	}
	w.buf = append(w.buf, byte(v))
	return w
}

// Varint writes an int64 as a zigzag-encoded Uvarint, so small-magnitude
// negatives stay compact.
func (w *Writer) Varint(v int64) *Writer {
	return w.Uvarint(uint64((v << 1) ^ (v >> 63)))
}

// Str writes a string as an Uvarint length followed by its bytes. Any bytes
// are allowed; nothing is escaped.
func (w *Writer) Str(s string) *Writer {
	w.Uvarint(uint64(len(s)))
	w.buf = append(w.buf, s...)
	return w
}

// Blob writes a byte slice as an Uvarint length followed by its bytes.
func (w *Writer) Blob(b []byte) *Writer {
	w.Uvarint(uint64(len(b)))
	w.buf = append(w.buf, b...)
	return w
}

// Addr writes an address as its bech32 string (see Str). This decodes cheaply
// and hands the reader a value it can use directly; the codec does not
// validate the address, which is the caller's business.
func (w *Writer) Addr(a address) *Writer { return w.Str(string(a)) }

// Bytes returns the accumulated payload. The slice aliases the Writer's
// internal buffer: it stays valid as long as you only read it, but Reset (and
// the writes that follow) will overwrite it, so copy it first if you intend to
// keep it across a Reset.
func (w *Writer) Bytes() []byte { return w.buf }

// Len is the number of bytes written so far.
func (w *Writer) Len() int { return len(w.buf) }

// Reset empties the Writer for reuse, keeping its capacity.
func (w *Writer) Reset() *Writer {
	w.buf = w.buf[:0]
	return w
}

// Reader reads values from a payload in the order they were written. It never
// panics: the first read that runs past the end (or overflows) sets a sticky
// error, after which every read returns a zero value. Read the fields you
// expect, then check Err once.
type Reader struct {
	buf []byte
	off int
	err error
}

// NewReader returns a Reader over b. It does not copy b.
func NewReader(b []byte) *Reader { return &Reader{buf: b} }

// Err returns the first error encountered, or nil. Once set it stays set.
func (r *Reader) Err() error { return r.err }

// More reports whether unread bytes remain and no error has occurred. Use it
// to read trailing optional fields.
func (r *Reader) More() bool { return r.err == nil && r.off < len(r.buf) }

// Done reports whether the whole payload was consumed with no error. Use it to
// reject trailing bytes a stricter caller would treat as malformed.
func (r *Reader) Done() bool { return r.err == nil && r.off == len(r.buf) }

// Remaining is the number of unread bytes.
func (r *Reader) Remaining() int {
	if r.off > len(r.buf) {
		return 0
	}
	return len(r.buf) - r.off
}

// fail records err (keeping the first) and reports false.
func (r *Reader) fail(err error) bool {
	if r.err == nil {
		r.err = err
	}
	return false
}

// take advances over n bytes, returning them, or fails.
func (r *Reader) take(n int) ([]byte, bool) {
	if r.err != nil {
		return nil, false
	}
	// Compare against the bytes that remain rather than r.off+n: with n coming
	// from a caller-supplied length (via int(Uvarint)), r.off+n can overflow
	// int64 and wrap negative, slipping past the check and panicking the slice.
	// len(r.buf)-r.off is always in [0, len]; n<0 catches a length so large its
	// int conversion went negative.
	if n < 0 || n > len(r.buf)-r.off {
		return nil, r.fail(ErrShort)
	}
	b := r.buf[r.off : r.off+n]
	r.off += n
	return b, true
}

// Byte reads one raw byte, or 0 on failure.
func (r *Reader) Byte() byte {
	b, ok := r.take(1)
	if !ok {
		return 0
	}
	return b[0]
}

// Bool reads a boolean. Any non-zero byte is true.
func (r *Reader) Bool() bool { return r.Byte() != 0 }

// Uint reads a fixed 8-byte big-endian uint64, or 0 on failure.
func (r *Reader) Uint() uint64 {
	b, ok := r.take(8)
	if !ok {
		return 0
	}
	return uint64(b[0])<<56 | uint64(b[1])<<48 | uint64(b[2])<<40 | uint64(b[3])<<32 |
		uint64(b[4])<<24 | uint64(b[5])<<16 | uint64(b[6])<<8 | uint64(b[7])
}

// Int reads a fixed 8-byte big-endian int64.
func (r *Reader) Int() int64 { return int64(r.Uint()) }

// Uvarint reads an unsigned LEB128 varint, or 0 on failure. A non-minimal
// encoding (trailing 0x80…0x00 groups) decodes to the same value rather than
// being rejected, so the format is not canonical: do not treat a payload's
// exact bytes as an identity. Only a value that cannot fit in 64 bits is
// refused (ErrOverflow).
func (r *Reader) Uvarint() uint64 {
	if r.err != nil {
		return 0
	}
	var x uint64
	var s uint
	for i := 0; i < 10; i++ {
		if r.off >= len(r.buf) {
			r.fail(ErrShort)
			return 0
		}
		b := r.buf[r.off]
		r.off++
		if b < 0x80 {
			if i == 9 && b > 1 {
				r.fail(ErrOverflow)
				return 0
			}
			return x | uint64(b)<<s
		}
		x |= uint64(b&0x7f) << s
		s += 7
	}
	r.fail(ErrOverflow)
	return 0
}

// Varint reads a zigzag-encoded Varint.
func (r *Reader) Varint() int64 {
	u := r.Uvarint()
	return int64(u>>1) ^ -int64(u&1)
}

// Str reads a length-prefixed string, or "" on failure.
func (r *Reader) Str() string {
	n := r.Uvarint()
	b, ok := r.take(int(n))
	if !ok {
		return ""
	}
	return string(b)
}

// Blob reads a length-prefixed byte slice. The result aliases the payload;
// copy it if you intend to keep it past the payload's lifetime.
func (r *Reader) Blob() []byte {
	n := r.Uvarint()
	b, ok := r.take(int(n))
	if !ok {
		return nil
	}
	return b
}

// Addr reads a length-prefixed bech32 string as an address (see Str). The
// codec does not check validity; use address.IsValid if you must.
func (r *Reader) Addr() address { return address(r.Str()) }
