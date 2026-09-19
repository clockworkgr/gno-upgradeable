# Reference

`gno.land/p/clockwork/app/v0`

The package you import. It bundles the [proxy layer](proxy.md) with verb
dispatch, a declared schema and schema-free state.

- [Threading `cur`](#threading-cur)
- [App](#app)
- [Handler](#handler)
- [Schema](#schema)
- [Args and the wire format](#args-and-the-wire-format)
- [Store](#store)
- [Admin verbs](#admin-verbs)
- [Errors](#errors)
- [Events](#events)

## Threading `cur`

Every method that cares who is calling takes `(_ int, rlm realm)`: your realm
threads its own `cur` in as data rather than crossing into this package. The
leading `int` keeps `realm` out of first position, where it would declare a
crossing function — which a `p/` package may not do at all.

| Inside those methods | Is |
|---|---|
| `rlm.IsCurrent()` | false for a stashed or replayed realm value — checked first |
| `rlm.Previous()` | the realm that crossed into your realm: the user, a governance realm, or a registering handler |
| `rlm.PkgPath()` | your realm's own path |

Call them as `a.Call(0, cur, verb, payload)` from your realm's crossing
functions. Never `cross(...)` into them.

## App

```go
func New(auth upgradeable.Authority) *App      // handlers must live under your path
func NewOpen(auth upgradeable.Authority) *App  // handlers may come from anywhere
func Owner(addr address) upgradeable.Authority
func Governed(paths ...string) upgradeable.Authority
```

`Owner` and `Governed` are re-exported so a realm using this package need not
import `upgradeable` as well. Both constructors panic on a nil authority —
there is no "nobody" authority; to reach that, freeze.

`New`'s restriction is that a handler must register from a realm nested under
your app's path (`…/app/impl/v1` under `…/app`). Deploying under that prefix
needs your namespace, so strangers cannot fill your pending set. `NewOpen`
drops it and leaves the authority as the only gate.

| Method | Does |
|---|---|
| `Bind(_ int, rlm realm)` | Teaches the app its own path. Call once, from `init`. |
| `Call(_ int, rlm realm, verb, payload string) string` | Look up, decode, validate, dispatch. |
| `Register(_ int, rlm realm, h Handler)` | Nominate the calling realm's handler. |
| `Admin(_ int, rlm realm, verb, arg string) string` | The whole governance surface; see [admin verbs](#admin-verbs). |
| `Store(_ int, rlm realm) *Store` | Hand the state to the live handler. |
| `Render(path string) string` | A gnoweb page: what serves, the API table, state size, authority. |
| `Schema() *Schema` | The live handler's declaration, or nil. |
| `Verbs() []string` | Enumerate the API. |
| `Signature(verb string) string` | One verb's declaration, or `""`. |
| `SchemaJSON() string` | The API as JSON, for tooling. |
| `Supports(verb string) bool` | Whether the live handler answers it. |
| `LivePath() string` | Path of the handler currently serving, or `""`. |
| `PendingPaths() []string` | Candidates awaiting acceptance. |
| `HistoryPaths() []string` | Handlers already served; non-empty means rollback is available. |
| `Extensions() []string` | Realms permitted to act as this app. |
| `Frozen() bool` | Whether upgradeability has ended. |
| `Authority() string` | Who may upgrade. |
| `Proxy() *upgradeable.Proxy` | The layer underneath, for typed entry points of your own. |

`Bind` is separate from `New` because a package-level var initializer runs
before there is a realm frame to read the path from. Until it has run, `Store`
panics with `ErrNotBound`.

## Handler

```go
type Handler interface {
	Schema() *Schema
	Handle(_ int, rlm realm, args *Args) string
}
```

`Schema` declares the API as data — a verb set rather than a method set. A
method set is compiled into the realm that declares it and can never grow.

`Handle` answers one call. By the time it runs the app has looked the verb up,
decoded the payload and checked every field, so the accessors on `Args` do not
return errors. Panic to fail; panics cross the realm boundary and abort the
transaction, so a caller cannot swallow them.

Return `Schema` as a package-level value rather than rebuilding it per call —
the app reads it on every dispatch. A handler declaring no verbs is refused at
`Register`, not at first call.

## Schema

```go
func NewSchema(verbs ...Verb) *Schema
func Op(name, doc string, result Kind, params ...Field) Verb
func P(name string, kind Kind, doc string) Field    // required
func Opt(name string, kind Kind, doc string) Field  // optional, must come last
```

| Kind | Accepts |
|---|---|
| `KindString` | anything |
| `KindInt` | int64, base 10 |
| `KindBool` | `true` or `false`, exactly |
| `KindAddress` | bech32, validated with `address.IsValid` |
| `KindNone` | result only — a verb that returns nothing meaningful |

`NewSchema` panics on a declaration that could not be served correctly: a
blank or duplicate verb name, an unknown or unusable kind, a duplicate
parameter name, or a required parameter after an optional one — which the
positional encoding could never supply. These are authoring mistakes, and a
handler carrying one should fail to deploy rather than mis-describe itself
forever.

| Method | Returns |
|---|---|
| `Names() []string` | verb names, sorted |
| `Lookup(name string) (Verb, bool)` | one declaration |
| `Verbs() []Verb` | a copy of all of them |
| `Signature(name string) string` | e.g. `add(text:string, urgent:bool?) -> int` |
| `Markdown() string` | the API as a table, for Render |
| `JSON() string` | the API for tooling |
| `Diff(prev *Schema) []string` | what upgrading from `prev` would break |

`Diff` is what `accept` runs. **Breaking:** a verb disappears, a parameter
disappears or changes kind or position, a new required parameter appears, or a
result kind changes. **Not breaking:** a new verb, a new optional parameter
appended, new documentation.

This is not static typing. Gno has no reflection, so nothing inspects your Go
types; validation happens at call time against declarations you wrote by hand.
A handler whose `switch` disagrees with its own schema is a bug the schema
cannot catch.

## Args and the wire format

A payload is **one CSV record**: stdlib, correctly quoted, hand-writable on a
gnokey command line. Fields are positional, in declaration order.

```
add       buy milk                 one field
add       "buy milk, eggs"         still one field; the comma survives
transfer  g1abc…,42,rent           three fields
list      (empty)                  none
```

```go
func Encode(v Verb, values ...string) string
```

Use `Encode` when one realm calls another app, so an encoding mistake fails
where it was made. It validates each value against its declared kind.

| Accessor | Returns |
|---|---|
| `Verb() string` | the verb being called |
| `Signature() string` | the declaration this payload was checked against |
| `Has(name string) bool` | whether an optional parameter was supplied |
| `String`, `Int`, `Bool`, `Address` | the value, or the zero value if optional and omitted |
| `Raw() []string` | the decoded fields in order |

Reading a parameter the verb never declared, or reading it as the wrong kind,
panics. That is a bug in the handler which no payload can fix, so it fails
loudly rather than returning a zero value that would be silently wrong.

Decoding costs gas in proportion to payload length; see [cost](cost.md).

## Store

Schema-free key/value state, owned by your realm.

```go
func (s *Store) Get(k string) string          func (s *Store) Set(k, v string)
func (s *Store) Has(k string) bool            func (s *Store) Delete(k string) bool
func (s *Store) Len() int                     func (s *Store) Keys() []string
func (s *Store) KeysWithPrefix(p string) []string
func (s *Store) GetInt(k string) int64        func (s *Store) SetInt(k string, v int64)
func (s *Store) AddInt(k string, d int64) int64
```

Keys are kept sorted, so `KeysWithPrefix` is how one store holds several
collections. An absent key and a key set to `""` both read as `""` — `Has` is
the difference.

**Where writes land.** `Store` is declared in this `p/` package but allocated
by your realm, so Gno's storage-realm borrow persists every write in the realm
that *owns* the object. That is what lets a handler realm mutate your state
while holding none of it.

**Who can reach it.** `App.Store` refuses any caller whose `cur` is not your
realm's — including a realm holding a perfectly valid `cur` of its own,
because that `cur` carries its own path. Extensions registered by the
authority are admitted; see [patterns](patterns.md#extending-a-frozen-api).

The accessor `Store` hands back carries the caller's `cur` and re-runs this
gate on every operation, so it cannot be retained past the call that obtained
it: stashing it aborts the transaction (a realm value cannot be persisted) and
a copy used after its frame returns fails `IsCurrent()`. A handler therefore
has full access only while it is serving; `rollback` and `freeze` end that
access completely. See
[limitations](limitations.md#accepting-a-handler-grants-it-full-access-while-it-serves).

## Admin verbs

`App.Admin` puts the whole governance surface behind one entry point, so your
realm declares one function instead of one per governance action.

| Verb | Arg | Effect |
|---|---|---|
| `accept` | path | make a candidate live, unless its schema breaks a caller |
| `accept-breaking` | path | the same, allowing a breaking schema change |
| `withdraw` | path | drop a candidate |
| `rollback` | — | restore the previous handler |
| `forget` | — | drop the rollback history, releasing its storage |
| `freeze` | — | end upgradeability, permanently |
| `extend` | path | let another realm act as this one |
| `unextend` | path | revoke that |
| `owner` | address | hand authority to an address |
| `govern` | paths | hand authority to governance realms, comma-separated |

Authority-gated, except that a realm may always withdraw its own candidate.
Returns `"ok"` or panics — including `app: unknown admin verb`.

If you would rather have named entry points for gnoweb, declare them yourself
and forward to `a.Proxy()`.

## Errors

All are panicked, not returned. A panic that crosses a realm boundary aborts
the transaction rather than unwinding, so `recover()` will not catch these; in
tests, use `revive(fn)`.

| Error | Message |
|---|---|
| `ErrNoHandler` | `app: no handler is live` |
| `ErrNotAHandler` | `app: live implementation does not satisfy Handler` |
| `ErrStaleRealm` | `app: realm value is not the caller's live cur` |
| `ErrNotBound` | `app: Bind has not been called from init` |
| `ErrForbidden` | `app: store is not reachable from this realm` |
| `ErrUnknownVerb` | `app: unknown admin verb` |
| `ErrNoSchema` | `app: a handler must declare at least one verb` |

Dispatch and decoding raise messages built at call time rather than these
sentinels, because they name the verb and its signature:

```
app: unknown verb "done"; this app answers add, list
app: add takes at most 1 parameter(s), got 2; signature is add(text:string) -> int
app: done: parameter id: expected an integer, got "abc"; signature is done(id:int) -> string
app: refusing a breaking upgrade to …/impl/v9: verb count removed — use the accept-breaking verb to override
```

## Events

Emitted by the proxy layer, so `pkg_path` on every one is
`gno.land/p/clockwork/upgradeable/v0` — index on the event type, not the
emitting path.

| Type | Attributes |
|---|---|
| `UpgradeProposed` | `impl` |
| `UpgradeWithdrawn` | `impl` |
| `UpgradeAccepted` | `impl`, `replaced` |
| `UpgradeRolledBack` | `impl`, `replaced` |
| `UpgradeHistoryDropped` | `dropped` |
| `UpgradeExtensionAdded` | `realm` |
| `UpgradeExtensionDropped` | `realm` |
| `UpgradeFrozen` | `impl` |
| `UpgradeAuthorityTransferred` | `from`, `to` |

Together these reconstruct which code served which block without replaying the
realm. What they do not carry is *why*.
