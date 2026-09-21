# wire

A schema-positional binary codec for gno — a compact, low-gas alternative to
packing call arguments as CSV or other delimited text.

```go
import "gno.land/p/clockwork/wire/v0"

// encode
payload := wire.NewWriter().Addr(to).Int(amount).Str(memo).Bytes()

// decode
r := wire.NewReader(payload)
to, amount, memo := r.Addr(), r.Int(), r.Str()
if err := r.Err(); err != nil { panic(err) }
```

## Why

gno charges gas per interpreted opcode, so a delimited text format pays per
byte: it scans every byte for separators and quotes, and parses every number
with `strconv`. A length-prefixed format lets the reader **slice** each field
out in a fixed number of opcodes, so decoding costs on the order of the field
count, not the payload length.

Measured in-package (`gas_test.gno`), decode gas per call:

| payload | CSV-style | wire | |
|---|--:|--:|--:|
| string, 8 chars | 47,035 | 30,259 | −36% |
| string, 60 chars | 275,678 | 30,259 | **−90%** |
| address + int + string | 283,003 | 84,734 | −71% |

wire is **flat in payload length** — a 60-char string decodes for the same gas
as an 8-char one — because it slices rather than scans.

## Pass it as `[]byte`

Give the payload to a realm as a `[]byte` argument, not a `string`. gnokey
sends a `[]byte` base64-encoded and the VM decodes it in **native Go** before
your code runs, so the envelope costs no interpreted gas:

```go
func Transfer(cur realm, payload []byte) string {
    r := wire.NewReader(payload)
    to, amount, memo := r.Addr(), r.Int(), r.Str()
    if r.Err() != nil { panic(r.Err()) }
    ...
}
```

```sh
gnokey maketx call -func Transfer -args "<base64 of the wire bytes>" ...
```

## The wire has no schema; the call order is the schema

Nothing on the wire says what type each value is. The reader must read the same
types in the same order the writer wrote them — that shared, out-of-band schema
is the whole point: no field tags, no type bytes, no delimiters, no quoting.
Values containing commas, quotes or newlines round-trip untouched.

## Format

| type | encoding |
|---|---|
| `Bool` | 1 byte (0/1) |
| `Byte` | 1 raw byte |
| `Uint`, `Int` | 8 bytes, big-endian (fixed; cheapest to decode) |
| `Uvarint`, `Varint` | LEB128 (varint; `Varint` is zigzag) — compact for small values |
| `Str`, `Blob` | `Uvarint` length, then the bytes |
| `Addr` | an address as its bech32 string (see `Str`) — decodes cheaply and is usable directly; use raw `Blob` of 20 bytes if you need the smallest wire size |

Fixed-width `Int`/`Uint` decode fastest; `Uvarint`/`Varint` are smaller on the
wire. Pick per field.

## Structs, slices, and nesting

The codec is scalars; structs and collections are patterns on top of it. A
struct is its fields inline; a slice is a count then its elements; nesting is
just more of the same. `example_structs_test.gno` has runnable `Transfer`
(flat) and `Order` (nested structs + two slices) codecs:

```go
func marshalOrder(o Order) []byte {
    w := wire.NewWriter().Uint(o.ID).Addr(o.Buyer)
    w.Uvarint(uint64(len(o.Items)))            // slice = count + elements
    for _, it := range o.Items {
        w.Str(it.SKU).Uvarint(it.Qty).Int(it.Price) // nested struct = fields inline
    }
    w.Uvarint(uint64(len(o.Tags)))
    for _, tg := range o.Tags {
        w.Str(tg)
    }
    return w.Bool(o.Paid).Str(o.Note).Bytes()
}
```

**Untrusted counts: never allocate on a length you have not bounded.** Every
element costs at least one byte, so a count larger than the bytes remaining is
a lie — reject it before `make`:

```go
n := r.Uvarint()
if r.Err() != nil { return nil, r.Err() }
if n > uint64(r.Remaining()) { return nil, errors.New("count exceeds payload") }
items := make([]Item, 0, n)
for k := uint64(0); k < n; k++ {
    it := Item{SKU: r.Str(), Qty: r.Uvarint(), Price: r.Int()}
    if r.Err() != nil { return nil, r.Err() } // truncated or hostile: stop
    items = append(items, it)
}
```

## Schemas and codegen

Hand-writing the marshal and unmarshal keeps the encoder and decoder in step by
convention — both must call the same types in the same order. When you want that
guaranteed, and the same types and codecs generated for other languages, declare
the shape once with [wire/schema](../schema/v0): it fixes the field order from
the declaration (sorted by name, no field numbers) and generates the struct and
`MarshalWire`/`Unmarshal` for you, and `gno.land/p/clockwork/orderpb/v0` is a
worked example of that output. The wire format is unchanged — the schema is
metadata that never reaches the wire.

## Gas: structs vs a hand-rolled text codec

Encode and decode of the two example structs, wire versus a delimited-text
codec (`gas_structs_test.gno`, per-op):

| operation | text | wire | |
|---|--:|--:|--:|
| simple encode | 37,136 | 54,110 | +45% |
| simple decode | 335,534 | 93,362 | **−73%** |
| complex encode | 438,491 | 241,847 | −45% |
| complex decode | 2,313,280 | 472,150 | **−80%** |

Decoding — what a contract does with incoming arguments — is where it counts,
and wire is 73–80% cheaper; a nested text payload costs 2.3M gas to parse
(multi-level splitting plus `strconv` per number) against wire's 472k. Encoding
is marginally dearer than text for a tiny payload (a `Writer` allocates where
two string concatenations do not) and cheaper for a complex one — and encoding
usually happens off chain anyway, where its gas is free.

## Safety

A `Reader` never panics on malformed or truncated input, including a hostile
payload that claims a huge length. Every read is bounds-checked; the first
failure sets a sticky error (`ErrShort` or `ErrOverflow`), later reads return
zero values, and `Err()` reports it. Read the fields you expect, then check
`Err()` once. Use `More()` for optional trailing fields and `Done()` to reject
trailing bytes.

Two properties worth knowing: `Blob` returns a slice that aliases the payload
(copy it if you keep it; `Str` copies for you), and varints are decoded
non-strictly — a non-minimal encoding decodes to the same value rather than
being rejected, so the byte layout of a payload is not a canonical identity.
Neither affects reading call arguments; both matter if you alias buffers or
hash payloads.

## Versioning

The codec itself carries no version. If your payloads will evolve, write a
version as the first field (a `Byte` or `Uvarint`) and branch on it when
reading. Appending new fields at the end is backward-compatible: an old reader
stops at `More() == false`, a new reader reads the extra field.
