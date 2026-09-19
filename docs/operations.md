# Operations

Every command here was run against a local chain built from gno master. Add
`-remote` for a real network.

- [Setup](#setup)
- [First deployment](#first-deployment)
- [Shipping an upgrade](#shipping-an-upgrade)
- [Emergency: a bad handler is live](#emergency-a-bad-handler-is-live)
- [Transferring authority](#transferring-authority)
- [Freezing](#freezing)
- [Inspecting a deployed app](#inspecting-a-deployed-app)
- [Troubleshooting](#troubleshooting)

## Setup

```sh
gnoland start -lazy -skip-failing-genesis-txs
```

Shared flags:

```sh
ADD="-broadcast -chainid dev -gas-fee 20000000ugnot -gas-wanted 250000000"
CALL="-pkgpath gno.land/r/acme/tasks -broadcast -chainid dev \
      -gas-fee 5000000ugnot -gas-wanted 40000000"
```

`gnoland` answers RPC at height 0, before consensus is producing blocks, so a
transaction sent the moment the port opens fails inside `consensus/state.go`.
Wait for a block rather than sleeping:

```sh
until [ "$(gnokey query --remote tcp://127.0.0.1:26657 . 2>/dev/null; \
           curl -s localhost:26657/status | \
           sed -n 's/.*"latest_block_height": *"\([0-9]*\)".*/\1/p')" -ge 2 ]; do sleep 1; done
```

## First deployment

Order matters — each package imports the one before it.

```sh
gnokey maketx addpkg -pkgdir gno.land/p/clockwork/upgradeable/v0 \
  -pkgpath gno.land/p/clockwork/upgradeable/v0 $ADD you
gnokey maketx addpkg -pkgdir gno.land/p/clockwork/app/v0 \
  -pkgpath gno.land/p/clockwork/app/v0 $ADD you
gnokey maketx addpkg -pkgdir gno.land/r/acme/tasks \
  -pkgpath gno.land/r/acme/tasks $ADD you
gnokey maketx addpkg -pkgdir gno.land/r/acme/tasks/impl/v0 \
  -pkgpath gno.land/r/acme/tasks/impl/v0 $ADD you
```

The last emits `UpgradeProposed`. Nothing serves until the authority accepts:

```sh
gnokey maketx call $CALL -func Manage -args accept -args gno.land/r/acme/tasks/impl/v0 you
gnokey query vm/qeval -data 'gno.land/r/acme/tasks.Verbs()'
```

**Before a real network:** the namespace must be one you own, and `Admin` must
be your address. Neither can be changed afterwards — the namespace because the
path is permanent, `Admin` because the source is.

## Shipping an upgrade

```sh
# 1. deploy — this registers, it does not serve
gnokey maketx addpkg -pkgdir gno.land/r/acme/tasks/impl/v1 \
  -pkgpath gno.land/r/acme/tasks/impl/v1 $ADD you

# 2. review what is now pending, and read the code at that path on chain
gnokey query vm/qeval -data 'gno.land/r/acme/tasks.PendingPaths()'
gnokey query vm/qfile -data 'gno.land/r/acme/tasks/impl/v1'

# 3. accept — refused if the schema would break a caller
gnokey maketx call $CALL -func Manage -args accept -args gno.land/r/acme/tasks/impl/v1 you

# 4. verify
gnokey query vm/qeval -data 'gno.land/r/acme/tasks.Verbs()'
gnokey maketx call $CALL -func Call -args <a real verb> -args <a real payload> you
```

Read the source at the path (step 2), not the branch you were shown. The full
checklist is in [security](security.md#reviewing-an-upgrade).

Leave the previous release in history until the new one has proven itself —
`forget` is what ends your ability to roll back.

If the upgrade is deliberately breaking:

```sh
gnokey maketx call $CALL -func Manage -args accept-breaking -args …/impl/v1 you
```

## Emergency: a bad handler is live

Every call routes through it, so a panicking handler means every call fails.
Roll back first, diagnose after.

```sh
gnokey maketx call $CALL -func Manage -args rollback -args "" you
gnokey query vm/qeval -data 'gno.land/r/acme/tasks.LivePath()'
```

The displaced release returns to `Pending`, so a fix can be accepted without
redeploying it. To stop it being accepted again by accident:

```sh
gnokey maketx call $CALL -func Manage -args withdraw -args …/impl/v1 you
```

Rollback stops the handler serving, and it cannot reach state any other way:
the store accessor is bound to the call that obtained it and cannot be retained
(a handler that tries to stash it aborts the transaction), so a rolled-back
handler is fully inert going forward — buggy or malicious alike. Two things
rollback does **not** do:

- **Revert state.** Anything the bad version wrote while it was live is still
  written. Repair it through whatever verbs exist — and if none can express
  the repair, ship one that can.
- **Undo handler-local state.** State a version kept in its own realm is still
  there if you roll forward to it again.

Going back more than one version is one `rollback` per step.

## Transferring authority

```sh
gnokey maketx call $CALL -func Manage -args owner  -args g1… you
gnokey maketx call $CALL -func Manage -args govern -args gno.land/r/gov/dao you
```

Comma-separate several paths to overlap old and new during a handover. Verify
before you lose access — a wrong path locks the app permanently, because
nothing else can authorize a correction:

```sh
gnokey query vm/qeval -data 'gno.land/r/acme/tasks.Authority()'
```

## Freezing

```sh
gnokey maketx call $CALL -func Manage -args freeze -args "" you
```

```
EVENTS: [{"type":"UpgradeFrozen",…},{"bytes_delta":-1996,"fee_refund":{"amount":"199600"}}]
```

Afterwards every mutating call fails, including the authority's:

```
Data: upgradeable: proxy is frozen
```

The app keeps serving. There is no unfreeze.

## Inspecting a deployed app

All free reads.

```sh
E="gnokey query vm/qeval -data"

$E 'gno.land/r/acme/tasks.Verbs()'         # the API
$E 'gno.land/r/acme/tasks.Signature("add")'
$E 'gno.land/r/acme/tasks.SchemaJSON()'    # the API, for tooling
$E 'gno.land/r/acme/tasks.LivePath()'      # what is serving
$E 'gno.land/r/acme/tasks.Authority()'     # who can change it

gnokey query vm/qfile   -data 'gno.land/r/acme/tasks/impl/v1'   # the source
gnokey query vm/qrender -data 'gno.land/r/acme/tasks:'          # the summary page
```

`Render` shows what serves, the API as a table, state size, authority,
extensions, pending candidates and history in one view.

To reconstruct history from events, index on the event **type** — `pkg_path`
on every one of them is the `p/` package, not your realm. See
[reference](reference.md#events).

## Troubleshooting

| Error | Cause | Fix |
|---|---|---|
| `package already exists: …` | Redeploying an occupied path | That is the rule this repo exists for. Deploy a new handler path and accept it. |
| `app: no handler is live` | Deployed but never accepted | `Manage accept <path>` |
| `app: unknown verb "x"; this app answers …` | Typo, or the live handler does not declare it | `Verbs()` |
| `app: … takes at most N parameter(s)` | Wrong field count | `Signature(verb)` |
| `app: … parameter id: expected an integer` | Wrong kind in the payload | The message gives the signature |
| `app: refusing a breaking upgrade …` | The candidate's schema breaks a caller | Fix it, or `accept-breaking` if you mean it |
| `app: a handler must declare at least one verb` | Empty schema | Declare the API |
| `app: Bind has not been called from init` | The realm's `init` is missing `a.Bind(0, cur)` | Add it |
| `app: store is not reachable from this realm` | Something other than the live handler called `Store` | Expected — or register it with `Manage extend` |
| `upgradeable: caller is not the authority` | Wrong signer, or authority transferred | `Authority()` |
| `upgradeable: candidate realm is not nested under this one` | Handler deployed outside `…/app/impl/*` | Redeploy under your app's path, or build with `NewOpen` |
| `upgradeable: only a deployed realm can register a candidate` | `Register` called from a user tx or `maketx run` | Registration comes from a deployed realm's `init` |
| `upgradeable: proxy is frozen` | Frozen | Nothing. Deploy a new app at a new path. |
| `upgradeable: no previous release to roll back to` | First release, or `forget` was called | Deploy a fixed handler and accept it |
| `cannot persist object of type defined in the private realm …` | Handler has `private = true` | Remove it; private realms cannot be handlers |
| `out of gas … during simulation` | `-gas-wanted` too low | 250M for `addpkg`, 40M for calls |
| A `p/nt/…` type error contradicting `$GNOROOT` | A stale copy in `$GNOHOME/pkg/mod` shadows `$GNOROOT` for the type checker | Clear the cached package; `gno doc` reads `$GNOROOT` and will disagree |
