# Patterns

Decisions you make once, and what each one costs.

- [Schema or typed](#schema-or-typed)
- [Where state goes](#where-state-goes)
- [Extending a frozen API](#extending-a-frozen-api)
- [How authority should evolve](#how-authority-should-evolve)
- [Versioning paths](#versioning-paths)
- [Threading `cur`](#threading-cur)
- [When not to do any of this](#when-not-to-do-any-of-this)

## Schema or typed

The first decision, and the only one that is hard to reverse.

**[Schema](reference.md)** — one `Call(verb, payload)` entry point, an API
declared as data. Verbs can be added forever, callers can enumerate them,
payloads are checked before your code runs, and upgrades are diffed so you
cannot silently drop one. What you give up is Go types at the boundary:
arguments are strings you encode, and a misspelled verb is a runtime panic
rather than a compile error.

**[Typed](proxy.md)** — real signatures. Callers and importing realms get
types checked by the compiler and gnoweb lists every function. What you give
up is growth: the method set is compiled into a realm that can never be
redeployed, so adding an operation means [a whole extra realm](#extending-a-frozen-api).

Default to schema. Choose typed when the API is small, you can name it today,
and other realms will import yours rather than call it from outside.

**Or both.** An app realm can carry hand-written typed entry points beside
`Call`, forwarding to `a.Proxy()`. Start generic, promote the verbs that
settle down — each one becomes permanent the moment you deploy it, so promote
when you are sure, not before.

## Where state goes

Three places. Most applications want the first, and the second by accident.

### In the permanent realm (default)

The `Store` your realm holds. Writes from the handler persist in your realm
because of Gno's storage-realm borrow, so replacing the handler does not touch
the data.

Use it for everything users care about: balances, registries, the records.

### In the handler realm

A version that needs bookkeeping no other version has can keep fields on its
own handler struct. Writes land in that realm because the method is declared
there. No coordination, nothing to design up front.

The cost is that it **does not roll back** — `Rollback` changes which handler
serves, not what any handler wrote — and the next version cannot see it
without importing the old realm and copying.

Use it for things genuinely about *this* version: counters, caches, a flag for
a migration it is performing.

### In a dedicated state realm

A third realm that owns the data and authorizes writers. `r/gov/dao` does this
with `memberstore`. Worth the extra realm when several realms share the state,
or when you want it to outlive the permanent realm too — then `app` and a
future `app/v2` are both just writers, the data never moves, and users migrate
at their own pace.

Authorize by the caller's path, and authorize **the permanent realm**, not the
handler: the handler threads the permanent realm's `cur`, so that is the path
the state realm sees. One constant instead of a list to maintain.

## Extending a frozen API

A realm's exported functions are fixed forever. A realm deployed *later* can
still serve typed entry points for it, without the original anticipating
anything. Two ordinary Gno mechanisms:

**Interface widening.** The proxy stores the implementation as `any`. A new
realm declares an interface of its own and asserts that value to it —
satisfaction in Gno is structural, so an implementation accepted later can
satisfy an interface written by someone else in a realm it never imports.

```go
// gno.land/r/you/app/ext/v1 — deployed long after gno.land/r/you/app
type Decrementer interface {
	Decrement(_ int, rlm realm, delta int64) int64
}

func Decrement(cur realm, delta int64) int64 {
	d, ok := app.LiveImpl().(Decrementer)   // app never heard of Decrementer
	if !ok {
		panic("ext/v1: the live implementation does not support Decrement")
	}
	return d.Decrement(0, cur, delta)
}
```

**An extension set.** Widening alone gets you a call that panics at the state,
because the accessor checks the caller's path. The authority registers the new
realm:

```sh
gnokey maketx call $CALL -func Manage -args extend -args gno.land/r/you/app/ext/v1 you
```

### This grants the authority nothing new

An authority that can `accept` an arbitrary implementation can already run
arbitrary code against the state. Naming a second realm that may do the same
changes *what is reachable*, not *who decides*. It does widen the surface a
reviewer must read, which is why `Extensions()` is public and `Render` lists
it.

### Verified

`gno.land/r/clockwork/counter` has no `Decrement` and never will:

```
$ gnokey query vm/qeval -data 'gno.land/r/clockwork/counter.Decrement(5)'
Data: name Decrement not declared
```

Before registration, the widened call reaches the state and stops. After one
`AddExtension`, it is a real entry point moving the same count:

```
Increment +10 via counter   → (10 int64)
Decrement 4 via ext/v1      → (6 int64)
counter.Count()             → 6
```

### What it costs

- A realm per extension, deployed and deposited forever.
- Callers must learn a second path; there is no single front door.
- The entry point is only as available as the implementation — roll back to a
  version without `Decrement` and it panics. Expose a `Supported()`.
- A bigger review surface.

With the schema approach you need none of this: add a verb.

## How authority should evolve

Three phases, and the authority should match.

**While you are the only one who cares** — an address. Fast, and nobody is
depending on you yet.

**Once other people depend on it** — a governance realm, via `govern`. The
proxy deliberately implements no quorum, timelock or multisig; those belong in
a realm that can evolve its own rules. Overlap old and new during the
handover, then narrow.

**When the realm is done changing** — `freeze`. Until it runs, every realm
importing yours trusts your authority rather than your code.

Do not skip to frozen while you still have bugs; do not stay on your own key
once the realm matters.

## Versioning paths

The version segment is always the **last** element: `…/app/impl/v1`, never
`…/app/v1/impl`. That is gno.land's own convention (`p/nt/avl/pager/v0`,
`r/gov/dao/impl/v0`), and `gnomod.toml` has no version field — the path suffix
is the only versioning mechanism there is.

The package name is the last element ignoring that suffix, so every version of
`…/app/impl/vN` is `package impl`. Import more than one with aliases.

Number from `v0` and never reuse a number, even for a version registered and
withdrawn without ever serving. The path is that code's permanent name.

## Threading `cur`

Two shapes, and the choice is not cosmetic.

**Non-crossing — `(_ int, rlm realm, …)`.** Your realm passes its own `cur` as
data. No realm transition, so the handler runs with your realm's identity:
state gates see your realm, and one constant authorizes every version. This is
what `app` does and what `r/gov/dao` does, and it should be your default.

**Crossing — `(cur realm, …)`, called with `cross(cur)`.** A real transition,
so the callee runs with its own identity. Gates see the callee's path, which
means they must track the live one. Use it when you *want* the callee to have
a distinct identity — because it holds its own coins, say.

Mixing is fine: `r/gov/dao` crosses for `Render` and threads for the rest.

## When not to do any of this

An upgradeable realm cannot export trust, costs storage per version, and asks
everyone downstream to trust your authority. Do not pay that unless the path
has to stay put.

**Just deploy `…/v2` at a new path** when the realm is young, when nobody
imports it, when users reach it through a link you control, or when the API
itself is what is changing. Point the old realm's `Render` at the new one and
move on. This is the normal way to ship on gno.land and it is fine.

**Use a proxy** when other realms import your path and cannot be asked to
change, when the realm holds balances or a registry that cannot move, or when
you need to fix behaviour in one transaction rather than coordinate a
migration.

**Use neither** when the realm should never change. Deploy it, add no proxy,
and the immutability is free — which is the strongest position on this chain
and the one everything else here is approximating.
