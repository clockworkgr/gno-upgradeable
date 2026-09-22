# Limitations

Read this before building on it. Several are unfixable in principle rather
than unimplemented, and the ones that are not still cost you something.

- [What is permanent](#what-is-permanent)
- [State](#state)
- [What can be a handler](#what-can-be-a-handler)
- [Storage and cost](#storage-and-cost)
- [Authority](#authority)
- [Failure modes](#failure-modes)
- [The schema is not a type system](#the-schema-is-not-a-type-system)
- [Testing](#testing)
- [If you are coming from EVM proxies](#if-you-are-coming-from-evm-proxies)

## What is permanent

### The realm path and its function signatures

Fixed at deploy. `AddPackage` refuses an occupied path, so the realm holding
your proxy will have exactly the functions it shipped with, forever.

With the [schema approach](reference.md) that costs you almost nothing,
because the only signature you are committing to is
`Call(cur realm, verb, payload string) string`. The application's verbs, their
parameters and their results all remain changeable. What you are deciding
permanently is that callers reach you through a verb string, and that your
realm is called what it is called.

With [typed entry points](proxy.md) it costs a great deal: the method set of
your interface and every exported signature are frozen, and adding an
operation later needs [an extension realm](patterns.md#extending-a-frozen-api).

### Parameter order, once a verb exists

The wire format is positional. Inserting a parameter, reordering, renaming or
changing a kind breaks every existing caller, and `accept` refuses it. The
only way to add a parameter to an existing verb is `Opt` at the end.

Design each verb's parameters in the order you want them forever. A verb you
have outgrown is cheap to replace — declare `add2`, deprecate `add` in its
doc, and drop `add` in a later version when nobody calls it (which `accept`
will make you confirm with `accept-breaking`).

### Whatever already-deployed callers compiled against

A realm that imported yours and calls `Call("add", …)` will keep calling
exactly that. Growing the API does not reach code written against the old one.

## State

### Rollback restores code, not data

`Rollback` changes which handler serves. It does not revert anything any
handler wrote, anywhere. If a bad version corrupted state before you caught
it, you still have to repair that state by hand through whatever verbs exist —
and if no verb can express the repair, you cannot make it until you ship one
that can.

### Handler-local state does not roll back either

State a version keeps on its own handler struct persists in that version's
realm. Roll back and forward again and it is still there, untouched by either
transition.

### There is no state migration

Nothing copies data between handler realms. If v1 kept state that v2 needs, v2
imports v1, reads it through exported getters and writes its own copy — paying
storage for both, with the original still deployed and still deposited.

### The store is untyped

Keys and values are strings. The schema describes your *API*, not your
storage: a typo in a key is a silent empty read, and nothing checks that the
value under `meta/next` is a number. `Has` distinguishes absent from empty;
that is the only help you get.

### Accepting a handler grants it full access while it serves

`Store` returns your state to code running on your realm's `cur` — the live
handler, and anything the handler chooses to pass that `cur` to. There is no
partial grant: while a handler is serving a call it can read and write
everything the realm holds. Registering an extension widens the set of realms
that may reach the state by one per call. **Review a handler's source before
you `accept` it** — acceptance is the trust boundary.

What the grant does **not** do is outlive the call. The accessor `Store` hands
back carries the caller's realm value and re-checks it on every operation, so
it cannot be kept:

- **Stashing it fails.** Assigning the accessor to realm state persists the
  realm value it carries, which the VM refuses ("cannot persist realm value"),
  aborting the transaction.
- **Replaying it fails.** Even held transiently, an accessor whose call frame
  has returned fails `IsCurrent()` on its next use.

So a handler's power ends when its call does, and `rollback` and `freeze` fully
neutralise it going forward: a rolled-back or superseded handler is never
dispatched to again and cannot reach state through a retained reference. This
is verified on chain — a handler that tried to stash the store had its
transaction aborted at the stash, and after rollback it could touch nothing.
What rollback does not undo is state a handler already wrote while it was live;
see [rollback restores code, not data](#rollback-restores-code-not-data).

## What can be a handler

### Not a private realm

The obvious idea — mark the handler `private = true` so you can redeploy it in
place — does not work. A private realm's objects cannot be stored outside it,
and registering is exactly that:

```
panic: cannot persist object of type defined in the private realm gno.land/r/you/app/impl/priv
```

### Not a `p/` package

Pure packages cannot declare crossing functions and cannot import `r/` realms.
A handler must be a realm.

### Not an ephemeral realm

`gnokey maketx run` executes in `/e/<addr>/run`, whose path does not outlive
the transaction. `Register` refuses it: a candidate filed under that path would
name code that will never be there.

## Storage and cost

### Registering writes to your realm

Deploying a handler writes the `Release` record and reference into **your**
realm's storage as well as its own. The deposit is charged to whoever signs,
so a spammer pays — but under `NewOpen` anyone can add entries. `New`'s
nesting rule means only your namespace can.

### History costs storage until you drop it

Every superseded release stays referenced so `rollback` can reach it. `forget`
and `freeze` release those references and refund (a measured −1,996 bytes,
0.2 GNOT, on the example).

### Superseded handler realms are never reclaimed

`forget` drops the proxy's *references*. The realms stay deployed at their own
paths holding their own deposits, forever. Nothing on gno.land evicts a live
realm's objects today — the open question is who receives the released deposit
— so every version you ship is a permanent cost.

### Deploys are expensive

The `p/` packages need ~54–74M gas; `-gas-wanted 40000000` fails with `out of
gas` during simulation. Budget 250M for `addpkg`, 40M for calls, and simulate
first. Payload decoding adds ~5,170 gas per byte; see [cost](cost.md).

## Authority

### An address authority is a single point of failure

Lose the key and the app is stuck in its current state forever: no upgrade, no
rollback, no transfer, not even `freeze`. Compromise it and the attacker owns
every future version. `NewAnyOf` with a second address is a crude backstop; a
governance realm is the real answer.

### No multisig, no timelock, no quorum

`accept` takes effect in the transaction that calls it. There is no delay in
which users can exit, and no threshold. Put those in a governance realm and
make it the authority — the proxy deliberately does not reimplement
governance.

### Authority realms are matched by exact path

A governance realm that redeploys at `…/v4` stops being authorized, silently,
until someone with the old authority updates the list — and if the old
authority *was* the realm that no longer runs, nobody can. List both paths
across a migration.

### Delegating to a mutable realm moves the problem

Pointing at a governance realm that is itself upgradeable does not solve
trust, it relocates it. Check whether the realm you delegate to is frozen.

### Nesting depends on `r/sys/names`

`New`'s nesting rule is only as strong as namespace ownership. On a chain
where `r/sys/names` is undeployed — which is how a local dev chain boots —
anyone can deploy under any path and the rule protects nothing.

## Failure modes

### A panicking handler takes the app down

Every call routes through it. A cross-realm panic aborts the transaction and
cannot be recovered by the caller, so every call fails until the authority
rolls back. Reads you route around the handler keep working, which is a reason
to route them around it.

### There is no dry run

You find out what a handler does by accepting it and calling it. The one thing
checked in advance is *shape*: `accept` diffs the declared schema and refuses
an upgrade that would break a caller. It says nothing about what the new code
does inside those signatures. Test on a local chain against a copy of your
state, and keep `rollback` available.

### `rollback` is one step at a time

It restores the immediately previous release. Going back two versions is two
transactions, each requeueing what it displaced.

### `forget` and `freeze` are irreversible

`forget` ends rollback. `freeze` ends everything, including its own reversal.
Neither asks twice. Freeze also **finalizes the extension set**: a registered
extension survives the freeze but can no longer be dropped, so it keeps its
access to the realm's state permanently. Review your extensions before
freezing — you cannot revoke one afterward.

### Nothing expires

A candidate sits in `Pending` until accepted or withdrawn. One registered a
year ago and forgotten is still one `accept` away from serving — review the
path, not your memory of it.

### No on-chain rationale

Events record what changed and when, never why.

## The schema is not a type system

Gno has no reflection, so nothing inspects your Go types. Validation happens
at call time against declarations you wrote by hand. Specifically:

- **A handler whose `switch` disagrees with its schema compiles fine.** A verb
  declared but not handled reaches your bottom `panic`; a verb handled but not
  declared is unreachable, because the app refuses it first. Only a test
  catches either.
- **`args.Int("id")` with a typo in the name panics at runtime**, not at build
  time.
- **Kinds are the five that survive a string encoding.** Anything nested — a
  list, a struct — is a format you choose and parse yourself on both sides,
  unchecked.
- **The diff compares declarations, not behaviour.** A handler can keep every
  signature and change what all of them mean.

## Testing

`gno test` does not deliver deployments as transactions, so the registration a
handler performs in its `init` is not visible to a test in another package.
The tests here re-do it explicitly; gno's own govDAO tests do the same for the
same reason. On chain it works — verified by the `UpgradeProposed` event on
the `addpkg` transaction.

`testing.NewCodeRealm` only builds `/r/` paths, so a `/p/` package's own tests
cannot satisfy the nesting rule; it is unit-tested through its predicate and
end-to-end through the realms.

`testing.SetRealm` applies to the frame that calls it. Calling it inside a
helper sets that helper's frame, which `cross(cur)` does not look at — setup
and the crossing call must sit in the same function.

## If you are coming from EVM proxies

| You expect | Here |
|---|---|
| `delegatecall` into arbitrary bytecode | Static imports; dispatch is an interface value |
| Storage slots shared by layout | A key/value store owned by the permanent realm, handed over through a gated accessor |
| Add a function in the new implementation | Add a verb — or, with typed entry points, a whole extra realm |
| Storage collision bugs | Cannot happen; there are no slots |
| Uninitialized-implementation attacks | Cannot happen; the handler realm runs its own `init` at deploy |
| Transparent/UUPS selector clashes | Cannot happen |
| An upgrade that changes everything silently | An upgrade whose shape is diffed and refused if it breaks a caller |

The trade is narrower power for a much smaller failure surface. Most of the
classic proxy CVEs are unrepresentable here.
