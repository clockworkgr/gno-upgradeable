# Security model

What the proxy enforces, what enforces it, and what it does not defend against.

- [The trust model](#the-trust-model)
- [What authenticates what](#what-authenticates-what)
- [Attacks and what stops them](#attacks-and-what-stops-them)
- [Not defended](#not-defended)
- [Reviewing an upgrade](#reviewing-an-upgrade)

## The trust model

Three parties.

**The authority** is trusted completely. It can put any code in front of your
users, in one transaction, with no delay. The one thing it cannot do
accidentally is change the API's shape: `accept` diffs the candidate's
declared schema and refuses an upgrade that would break a caller, so a
silent drop takes a deliberate `accept-breaking`. Everything below assumes the
authority is honest; nothing in the proxy constrains it except `Freeze`, which
constrains it permanently.

**A candidate handler** is trusted with nothing until accepted, and with
everything afterwards. Registration is open (to your namespace under `New`, to
anyone under `NewOpen`) precisely because registering grants no power.

**Everyone else** — other realms, other users — can read, and can do nothing
else. The interesting property is that this holds even for realms with a
perfectly valid `cur` of their own.

The whole design is about making the middle row cheap to review: an upgrade
names a path, the path names code anyone can read, and the naming cannot be
faked.

## What authenticates what

| Mechanism | Guarantees |
|---|---|
| `rlm.IsCurrent()` | The realm value is the caller's live `cur`, not a stashed or replayed one. Checked first in every mutating method. |
| `rlm.Previous()` | The immediate caller's identity, taken from a runtime-validated crossing frame. It cannot be supplied by the caller. |
| `rlm.PkgPath()` | The path of the realm the threaded `cur` belongs to. This is what the state gate compares. |
| Path from the frame | `Propose` records `rlm.Previous().PkgPath()`, never an argument, so a candidate's recorded path is where its code actually is. |
| `r/sys/names` | Deploying under `…/app/impl/*` needs the namespace, which is what makes `New`'s nesting rule mean anything. |
| Realm values are non-persistable | A `cur` cannot be stored and reused in a later transaction; the VM refuses. |

Notably absent: `unsafe.OriginCaller`. The proxy never reads the transaction
signer, so the tx.origin phishing class — a malicious realm acting as the user
who called it — does not apply.

## Attacks and what stops them

Each of these was run against a live chain.

**A payload that does not match the declaration.** Refused by the app before
the handler runs, naming the verb, the parameter and the signature — so a
handler never sees an unvalidated field and does not write validation code
that could differ from its own declaration.

**A stranger tries to accept a candidate.**
```
Data: upgradeable: caller is not the authority
```
`Authorized` compares `rlm.Previous()`, which the caller cannot forge.

**A hostile realm registers a candidate to get it in front of users.**
Under `New`, `ErrNotNested` — it cannot deploy under your namespace. Under
`NewOpen` it registers successfully and still serves nothing, because
acceptance is a separate authority-gated transaction.

**A candidate claims to live at a path it does not occupy**, so that a state
realm gating on `LivePath()` would authorize the wrong code. Impossible: the
path is read off the crossing frame.

**An unrelated realm reads or writes the shared state.**
```
Data: counter: state is reachable only through gno.land/r/clockwork/counter,
      not from gno.land/r/clockwork/intruder
```
It holds a valid `cur` — and is refused precisely because that `cur` is its
own. `r/clockwork/intruder` exists in this repo to demonstrate it.

The accessor it returns carries that `cur` and re-checks it on every read and
write, so the boundary is "is this realm running on a live cur right now",
not merely "did it obtain the store once". An accepted handler that stashes the
accessor cannot use it later: the stash aborts the transaction (a realm value
cannot be persisted) and a copy used after its frame returns fails
`IsCurrent()`. So access ends with the call — see
[limitations](limitations.md#accepting-a-handler-grants-it-full-access-while-it-serves).

**A realm stashes a `cur` from an earlier call and replays it.** `IsCurrent()`
returns false; realm values cannot be persisted in the first place.

**An authority is configured with a blank realm path**, which would match every
user call (`PkgPath()` is `""` for a direct transaction). `NewRealmAuthority`
panics with `ErrBadRealmPath` at construction, as it does for a
whitespace-padded path that would match nobody.

**Freezing with nothing live**, which would leave the realm permanently unable
to answer a call. Refused with `ErrNoImpl`.

**Redeploying the permanent realm to replace its code.**
```
Data: package already exists
```
This is the chain's rule, not the proxy's, and it is the reason the proxy
exists.

## Not defended

- **A malicious or compromised authority.** It can accept anything. Use a
  governance realm; `Freeze` when you are done.
- **A malicious handler, while it is live.** It runs with the permanent realm's
  `cur` and can do anything that realm can, including corrupting state through
  the verbs it serves. The schema constrains its *shape*, not its behaviour:
  every signature can stay identical while every one of them means something
  new. Review before accepting. What it *cannot* do is retain that power: the
  store accessor is bound to the call and cannot be stashed or replayed, so
  `rollback` and `freeze` end its access completely (verified on chain). What
  they do not undo is state it wrote while live — repair that through the
  realm's own verbs.
- **`cur` forwarded by an accepted implementation.** It can hand the threaded
  realm value to a realm of its choosing. Acceptance is all-or-nothing.
- **Anything needing a delay.** `Accept` takes effect immediately; there is no
  window for users to exit.
- **Key loss.** An `AddrAuthority` whose key is gone leaves the realm stuck in
  its current state permanently — not even `Freeze` is reachable.
- **A mutable governance realm.** Delegating to one that can itself be upgraded
  moves the problem rather than solving it.
- **Bad state left by a bad version.** `Rollback` restores code, not data.

## Reviewing an upgrade

Before sending `Accept`:

1. **Read the code at the path, on chain** — `gnokey query vm/qfile` — not the
   branch you were shown. The path in `Pending()` is the authenticated fact;
   anything else is a claim.
2. **Compare the schemas.** `accept` refuses a breaking change, so a clean
   accept already tells you no caller breaks. It tells you nothing about
   behaviour behind those signatures.
3. **Check `gnomod.toml`** for `private` or unexpected imports.
4. **Diff against the live handler**, and check what it does with the
   `rlm` it is threaded: does it forward it anywhere?
5. **Check what state it touches**, and whether any change is irreversible
   under `Rollback`.
6. **Confirm rollback is available** — `HistoryPaths()` is non-empty and you
   have not called `Forget`.
7. **Have the rollback transaction drafted** before you send the accept.

After:

8. **Watch `UpgradeAccepted`**, and exercise a real call.
9. Leave the previous release in history until the new one has proven itself.
