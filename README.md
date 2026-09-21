# Upgradeable contracts for gno.land

A gno.land package path is permanent. Deploy to one twice and the chain refuses:

```
Data: package already exists
    0  gno/gno.land/pkg/sdk/vm/errors.go:80 - package already exists: gno.land/r/you/app
```

So a realm other people import cannot have its code replaced. This repository
is a way to build one anyway — where the path stays put and everything behind
it can change.

```go
package myapp

import "gno.land/p/clockwork/app/v0"

const Admin = address("g1…")

var a = app.New(app.Owner(Admin))

func init(cur realm)                              { a.Bind(0, cur) }
func Call(cur realm, verb, payload string) string { return a.Call(0, cur, verb, payload) }
func Register(cur realm, h app.Handler)           { a.Register(0, cur, h) }
func Manage(cur realm, verb, arg string) string   { return a.Admin(0, cur, verb, arg) }
func Store(_ int, rlm realm) *app.Store           { return a.Store(0, rlm) }
func Render(path string) string                   { return a.Render(path) }

func Verbs() []string              { return a.Verbs() }
func Signature(verb string) string { return a.Signature(verb) }
func SchemaJSON() string           { return a.SchemaJSON() }
```

Plus six more one-line forwards the template includes — `LivePath`,
`PendingPaths`, `HistoryPaths`, `Extensions`, `Frozen`, `Authority` — so an
operator can inspect the wiring with `vm/qeval` instead of reading a page.

That realm never changes again. Your application lives in a separate realm
behind it, and you replace that one whenever you like. The API is a **declared
schema**, so it can grow — and so it can be enumerated by callers, checked
before your code runs, and diffed at upgrade time to stop you silently
dropping a verb somebody depends on.

## Start here

```sh
cp -r gno.land/r/yourname/myapp  gno.land/r/<your-namespace>/<your-app>
grep -rl yourname gno.land/r/<your-namespace> | xargs sed -i '' 's/yourname/<your-namespace>/g'
# then set Admin to your address
gno test ./gno.land/...
```

The template is a working three-verb app with tests. [The guide](docs/guide.md)
takes it from there.

## Documentation

| | |
|---|---|
| **[Guide](docs/guide.md)** | From the template to a governed, upgradeable app — the whole path |
| **[Reference](docs/reference.md)** | `app`: Handler, Schema, Args, Store, admin verbs |
| **[Operations](docs/operations.md)** | Deploy, upgrade, roll back, freeze; troubleshooting |
| **[Cost](docs/cost.md)** | What dispatch and decoding cost, measured, and how to keep it down |
| **[Patterns](docs/patterns.md)** | Where state goes, how authority should evolve, growing the API, when *not* to do any of this |
| **[Limitations](docs/limitations.md)** | What this cannot do — read before building on it |
| **[Security](docs/security.md)** | What is enforced and by what; attacks run against it |
| **[The proxy layer](docs/proxy.md)** | `upgradeable`: the layer underneath, and typed realms for when you want real signatures |

## How it works

**The realm at the permanent path holds nothing but a pointer.** Every call
goes through whatever it currently points at. There is no `delegatecall` and
imports resolve statically — the indirection is an ordinary interface value.

**Implementations nominate themselves by being deployed.** Your handler realm
calls `Register` from its own `init`. The path it is filed under is read off
the crossing frame, never passed as an argument, so a candidate cannot claim
to have been authored by a path it does not occupy.

**Accepting is a separate transaction.** Nothing serves until the authority
accepts a path it can go and read — the same two-phase shape gno.land itself
uses when a chain parks a submission until an approver enables it.

**State stays at the permanent path.** The `Store` belongs to your realm and
is handed to the live handler through a gate keyed on the realm value threaded
in. Upgrading replaces the code that reads and writes your data; it does not
touch your data.

**The API is data, so it can grow and be checked.** Handlers declare verbs and
parameter kinds. Callers enumerate them (`Verbs`, `Signature`, `SchemaJSON`),
payloads are validated before your handler runs, and `accept` refuses an
upgrade whose schema would break an existing caller.

**Authority is pluggable and can be ended.** An address to start, a governance
realm when others depend on you, and `Freeze` when the realm is done changing
— permanently, because until then everyone downstream is trusting you rather
than your code.

## What's in here

```
gno.land/p/clockwork/app/v0           the package you import
gno.land/p/clockwork/upgradeable/v0   the proxy layer underneath it
gno.land/p/clockwork/wire/v0          a low-gas binary codec for call payloads (standalone)
gno.land/r/yourname/myapp             the template: copy this
gno.land/r/clockwork/todo             worked example: an API that grows
gno.land/r/clockwork/counter          worked example: typed entry points instead
gno.land/r/clockwork/intruder         a realm that exists to be refused
```

Everything here is verified against a local chain built from gno master, not
just unit-tested: the upgrade path, the refusals, the schema checks and the
gas numbers all come from transactions that ran.

## The four limitations that change designs

The [full list](docs/limitations.md) is longer and worth reading.

1. **The realm path and its function signatures are fixed at deploy.** With
   the schema approach the *application's* API still grows freely; what cannot
   change is `Call`'s own signature and the realm's name.
2. **Rollback restores code, not data.** Bad state written by a bad version
   survives it, and state a version kept for itself does not roll back at all.
3. **Every version you ship is a permanent cost.** Superseded handler realms
   stay deployed with their storage deposits; nothing reclaims them.
4. **An upgradeable realm cannot export trust.** Per gno's interrealm spec,
   *"two mutable (upgradeable) realms cannot export trust unto the chain
   because functions declared in those two realms can be upgraded."*
   `Freeze` is how a realm leaves that category.
