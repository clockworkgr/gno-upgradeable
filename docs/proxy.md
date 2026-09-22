# The proxy layer

`gno.land/p/clockwork/upgradeable/v0`

[`app`](reference.md) is built on this, and most people should use `app`. Reach
for the proxy directly when you want **typed entry points** — real signatures
that gnoweb lists and other realms can import and call with real Go types —
and are willing to pay for them by freezing your API.

- [The trade](#the-trade)
- [Building a typed realm](#building-a-typed-realm)
- [Proxy](#proxy)
- [Authority](#authority)
- [Release](#release)
- [Errors](#errors)

## The trade

| | `app` (schema) | proxy directly (typed) |
|---|---|---|
| Entry point | one `Call(verb, payload)` | `Increment(cur realm, delta int64) int64` |
| Callers get | strings they encode | Go types, checked at compile time |
| gnoweb shows | one function, plus your schema | every function |
| Another realm importing you | calls `Call` | calls your function |
| Adding an operation | a line in the schema | [a whole extra realm](patterns.md#extending-a-frozen-api) |
| API discoverable | `Verbs`, `SchemaJSON` | by reading source |
| Payloads checked | before your code runs | by the compiler |

Typed is right when the API is small, you can name it now, and other realms
will import yours. Schema is right when you cannot name it yet or expect it to
grow. `gno.land/r/clockwork/counter` is the typed example;
`gno.land/r/clockwork/todo` is the other.

They compose: an `app` realm can carry hand-written typed entry points beside
`Call`, forwarding to `a.Proxy()`. Start generic, add typed entry points for
the verbs that settle down — each becomes permanent the moment you deploy it.

## Building a typed realm

Four things live in the permanent realm: the interface, the state, the proxy,
and the entry points.

### The interface

Declare it here, not in a `p/` package and not in an implementation, so every
version agrees on one type identity and the declaration sits in a file that
can never change.

```go
type Counter interface {
	Increment(_ int, rlm realm, delta int64) int64
	Describe(_ int, rlm realm) string
}
```

The `(_ int, rlm realm)` shape is deliberate. These are **non-crossing**
methods: the permanent realm threads its own `cur` in as data rather than
crossing into the implementation. Because no crossing happens, the
implementation runs with the permanent realm's identity — so when it calls
back into `Store`, the gate sees *the permanent realm*, not the
implementation. One gate then serves every version with no allowlist to
maintain. `r/gov/dao` threads its own `DAO` interface the same way.

### The state

```go
// The state itself, at the permanent path.
var count int64
```

The write persists *here* because the code that performs it is declared in
this realm: calling it from an implementation realm borrows the storage
context back here. A field the implementation set directly would not be
reachable at all.

### The gate

Do **not** hand the state out as a raw pointer. A raw pointer can be stashed
in a package variable and used forever, so an accepted implementation would
keep write access after it was rolled back or the realm frozen. Instead return
an accessor that carries the caller's `cur` and re-checks it on every
operation:

```go
type StateRef struct{ rlm realm }

func Store(_ int, rlm realm) *StateRef {
	assertStateAccess(0, rlm)
	return &StateRef{rlm: rlm}
}

func (r *StateRef) Count() int64          { assertStateAccess(0, r.rlm); return count }
func (r *StateRef) Add(delta int64) int64 { assertStateAccess(0, r.rlm); count += delta; return count }
func (r *StateRef) Set(v int64)           { assertStateAccess(0, r.rlm); count = v }

func assertStateAccess(_ int, rlm realm) {
	if !rlm.IsCurrent() {
		panic("counter: realm value is not the caller's live cur")
	}
	if c := rlm.PkgPath(); c != selfPath && !proxy.IsExtension(c) {
		panic("counter: state is not reachable from " + c)
	}
}
```

Because `StateRef` holds a realm value, it cannot be persisted — assigning it
to realm state aborts the transaction ("cannot persist realm value") — and a
copy used after its frame returns fails `IsCurrent()`. So the accessor lives
and dies with the exact call that obtained it, which is the only window in
which the caller is genuinely the live implementation (or a registered
extension). This is the same guarantee [`app`](reference.md#store) gives its
`Store`; a typed realm must build it by hand, and getting it wrong is the
capability leak this pattern exists to avoid.

### The proxy and entry points

```go
const Admin = address("g1…")

var (
	proxy    *upgradeable.Proxy
	selfPath string
)

func init(cur realm) {
	selfPath = cur.PkgPath()
	proxy = upgradeable.New(upgradeable.NewAddrAuthority(Admin))
}

func Increment(cur realm, delta int64) int64 { return live().Increment(0, cur, delta) }
func Count() int64                           { return count }

func Register(cur realm, impl Counter) { proxy.Propose(0, cur, impl) }
func Accept(cur realm, pkgPath string) { proxy.Accept(0, cur, pkgPath) }
func Rollback(cur realm)               { proxy.Rollback(0, cur) }
func Freeze(cur realm)                 { proxy.Freeze(0, cur) }

// The hook that lets the API grow later. See patterns.md.
func LiveImpl() any { v, _ := proxy.TryImpl(); return v }
```

`Register` takes `Counter`, not `any` — that is where the interface is
enforced, so a candidate of the wrong shape fails to deploy rather than
panicking on first call after you accept it.

Reads that need no interpretation (`Count`) should skip the implementation:
they keep working between an accepted upgrade and whatever the new version
decides to do, and cost no dispatch.

The implementation realm lives under the permanent realm's path and registers
itself from `init`:

```go
func init(cur realm) { counter.Register(cross(cur), instance) }
```

## Proxy

```go
func New(auth Authority) *Proxy      // candidates must be nested under the holder's path
func NewOpen(auth Authority) *Proxy  // any realm may register
```

### Reads

None take `rlm`; all return copies.

| Method | Returns |
|---|---|
| `Impl() any` | the live implementation; **panics `ErrNoImpl`** if none |
| `TryImpl() (any, bool)` | the same, without panicking |
| `Live() (Release, bool)` | the live release |
| `LivePath() string` | its realm path, or `""` |
| `Pending() []Release` | candidates, ordered by path |
| `History() []Release` | releases already served, oldest first |
| `Extensions() []string` | realms allowed to act as the holder |
| `IsExtension(pkgPath string) bool` | whether one is (false for `""`) |
| `Frozen() bool` | whether upgradeability has ended |
| `Authority() Authority` | the current authority |

### Writes

Every one calls `assertMutable` first, so **all of them fail with `ErrFrozen`
once frozen**, including the authority's own calls.

| Method | Caller | Notes |
|---|---|---|
| `Propose(_ int, rlm realm, impl any)` | any deployed realm | Path read off the crossing frame, never an argument. Re-registering replaces. Refuses user calls and ephemeral `/e/` realms. |
| `Accept(_ int, rlm realm, pkgPath string)` | authority | Immediate; no timelock. Files the replaced release in history. |
| `Withdraw(_ int, rlm realm, pkgPath string)` | authority, or the realm itself | So a superseded candidate stops costing storage without the authority acting. |
| `Rollback(_ int, rlm realm)` | authority | One step. Returns the displaced release to pending so a fix can be accepted without redeploying. |
| `Forget(_ int, rlm realm)` | authority | Drops history and its storage. **Ends rollback.** |
| `AddExtension(_ int, rlm realm, pkgPath string)` | authority | Grants no new power; see [patterns](patterns.md#extending-a-frozen-api). |
| `DropExtension(_ int, rlm realm, pkgPath string)` | authority | The realm stays deployed; it just stops reaching the state. |
| `TransferAuthority(_ int, rlm realm, auth Authority)` | authority | Panics on nil. |
| `Freeze(_ int, rlm realm)` | authority | No unfreeze. Refuses with nothing live. Clears pending and history; **finalizes extensions** — the registered set survives (reachable code the frozen impl may depend on) but can no longer be added to or dropped, so review it before freezing. |
| `AssertAuthorized(_ int, rlm realm)` | — | For wrappers doing work before delegating. |

## Authority

```go
type Authority interface {
	Authorized(addr address, pkgPath string) bool
	String() string
}
```

Handed the caller's identity, decomposed: `addr` is
`rlm.Previous().Address()`, `pkgPath` is `rlm.Previous().PkgPath()`. A direct
user transaction has an **empty `pkgPath`** — which is not a realm, it is
every user call, so a path check must reject it explicitly.

| Implementation | Authorizes |
|---|---|
| `NewAddrAuthority(addr)` | one address, signing directly or acting through a realm at that address |
| `NewRealmAuthority(paths...)` | a fixed set of realm paths — the `r/gov/dao` shape |
| `NewAnyOf(auths...)` | any member; the handover shape |

`NewRealmAuthority` panics on an empty list, and on a blank or padded entry: a
blank one would match every user call, a padded one would match no caller at
all, and both are silent. More than one path is allowed so authority can move
without a gap.

## Release

Returned by value, so a reader cannot rewrite history.

```go
func (r Release) PkgPath() string // authenticated at registration
func (r Release) Impl() any
func (r Release) Height() int64
func (r Release) IsZero() bool
```

## Errors

| Error | Message |
|---|---|
| `ErrNoAuthority` | `upgradeable: an authority is required` |
| `ErrUnauthorized` | `upgradeable: caller is not the authority` |
| `ErrStaleRealm` | `upgradeable: realm value is not the caller's live cur` |
| `ErrFrozen` | `upgradeable: proxy is frozen` |
| `ErrNoImpl` | `upgradeable: no implementation is live` |
| `ErrNotNested` | `upgradeable: candidate realm is not nested under this one` |
| `ErrNotARealm` | `upgradeable: only a deployed realm can register a candidate` |
| `ErrNilImpl` | `upgradeable: implementation is nil` |
| `ErrUnknownPath` | `upgradeable: no candidate registered at that path` |
| `ErrNoHistory` | `upgradeable: no previous release to roll back to` |
| `ErrBadAddress` | `upgradeable: invalid address` |
| `ErrBadRealmPath` | `upgradeable: authority realm paths must be non-blank and unpadded` |
