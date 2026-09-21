# wire/schema

A tiny, language-neutral schema for the [wire](../../v0) codec. It does **not**
change the wire format — it fixes which fields a message has, their types, and
the one order everything serializes in, so a gno encoder and a TypeScript or Go
decoder agree on the bytes without coordinating in code. It is also the single
source you generate types and marshal/unmarshal code from, in any language.

## No field numbers

There are no tags to assign. A message's wire order is its field names sorted
(byte-wise ascending). Given the same set of `(name, type)` pairs, every
implementation produces identical bytes. Declaration order is irrelevant.

Because the layout is derived from the names, **adding a field re-sorts it**, so
a schema change is a new message version, not an in-place edit — the same
versioning discipline the rest of this repo uses. Within a version the shape is
fixed. (If you need append-only evolution instead, add fields whose names sort
last, or version the message.)

## The IDL

```
message Item {
  price int
  qty   uint
  sku   string
}

message Order {
  buyer address
  id    uint
  items []Item
  note  string
  paid  bool
  tags  []string
}
```

A field is `name type`. A type is a scalar keyword, a message name, `[]scalar`,
or `[]MessageName`. `Parse` reads this; `Schema.String` prints it back, sorted
and canonical. Nested-message cycles are rejected (a positional, inlined format
can't encode them); a message may hold a list of itself, since a list is
length-delimited.

## The cross-language spec

To generate for another language, follow two rules: **fields in name-sorted
order**, and this encoding per kind (all via the wire codec):

| kind | Gno type | wire call |
|---|---|---|
| `bool` | bool | `Bool` |
| `byte` | byte | `Byte` |
| `int` | int64 | `Int` (fixed 8B) |
| `uint` | uint64 | `Uint` (fixed 8B) |
| `varint` | int64 | `Varint` (zigzag LEB128) |
| `uvarint` | uint64 | `Uvarint` (LEB128) |
| `string` | string | `Str` (len-prefixed) |
| `bytes` | []byte | `Blob` (len-prefixed) |
| `address` | address | `Addr` (bech32 as `Str`) |
| `[]T` | []T | `Uvarint(len)` then each element |
| nested message | struct | its fields, inline, sorted |

A decoder must bound a list's count before allocating: cap the make at the
bytes remaining (each element is ≥1 byte), so a hostile count cannot
over-allocate. The generated code does this.

## Codegen

```go
src, err := schema.GenerateGno(s, "orderpb")
```

produces a struct per message plus `MarshalWire`/`Unmarshal…`, composing nested
messages and slices through internal helpers. `gno.land/p/clockwork/orderpb/v0`
is the generated output of the schema above, with its round-trip tests. This is
the reference generator; a TypeScript or Go one follows the same two rules.

## Dynamic codec

When you would rather carry a schema than generate code:

```go
b, err := s.Encode("Order", map[string]any{"id": uint64(9001), "tags": []any{"a"}, ...})
v, err := s.Decode("Order", b)
```

The dynamic and generated codecs walk fields in the same order, so they are
byte-for-byte interchangeable — a property this package tests directly
(`TestGeneratedEqualsDynamic`).

## What it is not

It is metadata: it never appears on the wire. It carries no defaults,
optionals or unions — a message is exactly its fields. Optionality is a
versioning or a trailing-field concern; see the wire package's notes on
`More()`.
