# Cost

Measured, not estimated. The per-operation figures come from `gas_test.gno`,
which runs 200 iterations and subtracts an empty loop; the transaction figures
come from a local chain built from gno master.

- [Per operation](#per-operation)
- [Whole transactions](#whole-transactions)
- [Why cost is per byte](#why-cost-is-per-byte)
- [Keeping it down](#keeping-it-down)
- [Storage](#storage)

## Per operation

| Operation | Gas |
|---|---|
| `Schema.Lookup`, first of four verbs | 7,279 |
| `Schema.Lookup`, last of four verbs | 10,911 |
| decode, verb with no parameters | 22,777 |
| decode, one 8-char string | 76,027 |
| decode, three fields (address, int, string — 47 chars) | 355,553 |
| decode, quoted payload (csv fallback) | 301,358 |
| `Encode`, one 8-char string | 85,202 |
| three typed accessor reads | 100,155 |

## Whole transactions

Single-sample, from a local chain on the current code. Whole-transaction gas
depends on store state — key count and id sizes — and drifts a few percent
between otherwise-identical calls, so these are orders of magnitude; the
per-operation figures above are the deterministic ones.

| Transaction | Gas |
|---|---|
| typed entry point, no decode (`counter.Increment 5`) | ~4.5M |
| `Call list` — no fields to decode | ~6.3M |
| `Call add "buy milk"` — one 8-char field | ~7.9M |
| `Call add`, one 60-char field | ~8.4M |

**Decoding is a small fraction of a call** — well under 5% of the totals above
— and scales with payload length at about **5,170 gas per byte**, measured
deterministically: a 60-char single field decodes in 344,890 gas against 76,027
for an 8-char one (`gas_test.gno`). A payload with a quote or newline falls
back to `csv.Reader`: a 47-char three-field payload costs 355,553 that way
versus 265,377 for the single-pass path.

Each store operation also re-runs the capability guard (an `IsCurrent` check, a
path comparison, and a scan of any extensions), so a handler that touches state
several times pays it several times. It is small next to the decode and the
storage write, but it is why the whole-transaction figures sit slightly above
what the same calls cost before the guard was added.

Note the fee model: gno charges the flat `-gas-fee` you specify, so gas bites
by forcing a higher `-gas-wanted` (and, on a network with a minimum gas price,
a proportionally larger fee) rather than as a per-unit charge.

## Why cost is per byte

Gno's `strings` package is **interpreted Gno, not native code**. Every byte
examined is interpreter work, so any string operation costs in proportion to
length, with a high constant factor.

| Component, on a 47-char payload | Gas |
|---|---|
| `strings.ContainsAny(payload, "\"\r\n")` | 438,873 |
| `strings.Split(payload, ",")` | 456,798 |
| `csv.NewReader(...).Read()` | 462,457 |
| single-pass byte scan (`splitPlain`) | 265,377 |
| three `Kind.parse` checks | 68,345 |

This is worth internalising beyond this package. The first version of the
decoder's fast path was `if !strings.ContainsAny(…) { strings.Split(…) }` —
two passes over the payload — and it measured **78% slower than simply using
`csv.Reader`**. Detecting the plain case and splitting in the same pass made
decoding 74% cheaper than the original and encoding 67% cheaper.

**On Gno, prefer one explicit byte loop to two library calls.** And measure,
because the intuition that a stdlib helper is cheaper than a parser is wrong
here.

## Keeping it down

- **Short payloads.** Cost is per byte, so a 20-character id beats a
  200-character blob. Put bulk data in the store under a key and pass the key.
- **Few parameters.** Each adds a `Kind.parse` (~23,000 gas) on top of the
  bytes it occupies.
- **Avoid quoting where it is free to do so.** A comma or quote in a value
  sends the payload down the `csv.Reader` path.
- **Route pure reads around `Call`.** A query needing no dispatch can be a
  plain exported function — and free reads through `vm/qeval` cost no gas at
  all. `counter.Count()` is the shape.
- **Do not fear `Schema.Lookup`.** At ~10,000 gas it is noise next to the
  decode, so a long verb list is not a problem.

## Storage

Deposits, at 100 ugnot/byte on the chain these were taken from. The two `p/`
packages are deployed once per chain, not once per app, and cost ~54M and ~74M
gas respectively.

| | Storage | Deposit |
|---|---|---|
| `addpkg` p/upgradeable/v0 | 25,055 B | 2.51 GNOT |
| `addpkg` your realm | ~20,000 B | ~2.0 GNOT |
| `addpkg` a handler | ~4,000 B + ~1,000 B into your realm | ~0.5 GNOT |
| `accept` | 138 B | 0.014 GNOT |
| `freeze` | −1,996 B | 0.20 GNOT refunded |

Deploying a handler writes into **your realm's** storage as well as its own —
the `Release` record and the reference. The deposit is charged to whoever
signs.

Every version you ship stays deployed at its own path with its own deposit,
forever; `forget` and `freeze` release only the proxy's references to them.
See [limitations](limitations.md#storage-and-cost).
