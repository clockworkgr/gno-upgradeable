# Guide

From the template to a governed, upgradeable application. The finished version
of every step is in `gno.land/r/clockwork/todo`.

- [Step 0: decide what is actually permanent](#step-0-decide-what-is-actually-permanent)
- [Step 1: copy the template](#step-1-copy-the-template)
- [Step 2: declare your API](#step-2-declare-your-api)
- [Step 3: write the handler](#step-3-write-the-handler)
- [Step 4: deploy](#step-4-deploy)
- [Step 5: ship a second version](#step-5-ship-a-second-version)
- [Step 6: settle the authority](#step-6-settle-the-authority)
- [Step 7: stop being upgradeable](#step-7-stop-being-upgradeable)

## Step 0: decide what is actually permanent

Less than you would think, which is the point — but not nothing.

**Permanent, decided now:**

- The realm path. `gno.land/r/you/app` is its name forever.
- `Call(cur realm, verb, payload string) string` and the other forwards. Their
  signatures are compiled into a realm that can never be redeployed.

**Not permanent, decided later and as often as you like:**

- Which verbs exist, what they take, what they return.
- What is stored and under which keys.
- Everything any of it does.

So the design question is not "what will my application do" — you can change
that. It is "is `Call(verb, payload)` the shape I want callers to use for the
next decade", and secondarily "do I want my namespace and name to be this".

If you need *typed* entry points — real signatures that gnoweb lists and other
realms can import — that is a different trade, and it makes the API permanent.
See [the proxy layer](proxy.md).

## Step 1: copy the template

```sh
cp -r gno.land/r/yourname/myapp gno.land/r/acme/tasks
cd gno.land/r/acme/tasks
grep -rl yourname . | xargs sed -i '' 's|yourname/myapp|acme/tasks|g'
sed -i '' 's|myapp|tasks|g' *.gno impl/v0/*.gno
```

Then open `tasks.gno` and set `Admin` to your address. That file is done; you
will not edit it again. Everything in it is a one-line forward: the six that
make the app work, three that let callers enumerate your API, and six that let
an operator inspect the wiring.

Check it still builds:

```sh
gno test ./gno.land/r/acme/...
```

## Step 2: declare your API

This is the part worth slowing down for. The schema is what callers read, what
payloads are checked against, and what future upgrades are diffed against.

```go
var schema = app.NewSchema(
	app.Op("add", "Create a task.", app.KindInt,
		app.P("text", app.KindString, "what to do")),

	app.Op("done", "Mark a task complete.", app.KindString,
		app.P("id", app.KindInt, "the id returned by add")),

	app.Op("list", "List every task.", app.KindString),
)
```

`Op(name, doc, result, params...)`, `P` for required, `Opt` for optional.
Kinds are `string`, `int`, `bool`, `address` and `none` — the ones that survive
a string encoding without ambiguity.

Three rules worth knowing before you write the list:

**Appending an optional parameter is the only way to add one later.** The wire
format is positional, so inserting or reordering breaks every existing caller,
and `accept` will refuse it. Design each verb's parameters in the order you
want them forever, and add with `Opt` at the end.

**Name verbs for what they do, not for how they are implemented.** `done` can
change meaning entirely in v2; `set-done-flag` cannot.

**Prefer few parameters over many.** Each one costs a validation pass, and a
long payload costs gas per byte — see [cost](cost.md). Bulk data belongs in
the store under a key you pass.

`NewSchema` panics on a declaration that could not be served correctly — a
duplicate verb, an unknown kind, a required parameter after an optional one.
Those fail at deploy rather than mis-describing your app forever.

## Step 3: write the handler

```go
func (h *handler) Handle(_ int, rlm realm, args *app.Args) string {
	st := tasks.Store(0, rlm)

	switch args.Verb() {
	case "add":
		id := st.AddInt("meta/next", 1)
		st.Set(key(id), args.String("text"))
		return strconv.FormatInt(id, 10)

	case "done":
		id := args.Int("id")
		if !st.Has(key(id)) {
			panic("tasks: no such task")
		}
		st.Set("done/"+pad(id), "1")
		return "ok"

	case "list":
		…
	}
	panic("tasks/impl/v0: declared but unhandled verb: " + args.Verb())
}
```

By the time `Handle` runs, the app has looked the verb up, decoded the payload
and checked every field against its declared kind. `args.Int("id")` cannot
fail — so the accessors do not return errors, and you do not write validation
code. Panic for anything the schema cannot express ("no such task").

**The store is your realm's, not this realm's.** `tasks.Store(0, rlm)` hands
back an object owned by the permanent realm, and Gno's storage-realm borrow
persists writes there. That is why your data survives every version of this
file. Keys are strings, so use prefixes to hold several collections —
`task/…`, `done/…`, `meta/next` — and zero-pad numeric ids if you want sorted
order to be numeric order.

**Keep the switch and the schema in sync yourself.** Nothing checks that. A
verb you declare but do not handle reaches the `panic` at the bottom, which is
why it is there rather than a silent fall-through. A test per verb is cheap.

## Step 4: deploy

Three transactions, then one to turn it on.

```sh
FLAGS="-broadcast -chainid dev -gas-fee 20000000ugnot -gas-wanted 250000000"

gnokey maketx addpkg -pkgdir gno.land/p/clockwork/upgradeable/v0 \
  -pkgpath gno.land/p/clockwork/upgradeable/v0 $FLAGS you
gnokey maketx addpkg -pkgdir gno.land/p/clockwork/app/v0 \
  -pkgpath gno.land/p/clockwork/app/v0 $FLAGS you
gnokey maketx addpkg -pkgdir gno.land/r/acme/tasks \
  -pkgpath gno.land/r/acme/tasks $FLAGS you
gnokey maketx addpkg -pkgdir gno.land/r/acme/tasks/impl/v0 \
  -pkgpath gno.land/r/acme/tasks/impl/v0 $FLAGS you
```

The last one emits `UpgradeProposed`. It is registered, not serving —
deploying nominates, and a second transaction decides:

```sh
CALL="-pkgpath gno.land/r/acme/tasks -broadcast -chainid dev \
      -gas-fee 5000000ugnot -gas-wanted 40000000"

gnokey maketx call $CALL -func Manage -args accept -args gno.land/r/acme/tasks/impl/v0 you
```

Two phases on purpose: the authority approves a *path* it can go and read, in
a transaction separate from the one that put the code there.

Now it answers, and it describes itself:

```sh
gnokey query vm/qeval -data 'gno.land/r/acme/tasks.Verbs()'
# (slice[("add" string),("done" string),("list" string)] []string)

gnokey maketx call $CALL -func Call -args add -args "buy milk" you
# ("1" string)
```

## Step 5: ship a second version

Copy `impl/v0` to `impl/v1`, add to the schema, add to the switch, deploy,
accept.

```go
var schema = app.NewSchema(
	app.Op("add", "Create a task.", app.KindInt,          // unchanged
		app.P("text", app.KindString, "what to do")),
	app.Op("done", "Mark a task complete.", app.KindString,
		app.P("id", app.KindInt, "the id returned by add")),
	app.Op("list", "List every task, marking the done ones.", app.KindString),

	app.Op("count", "How many tasks are still open.", app.KindInt),   // new
)
```

```sh
gnokey maketx addpkg -pkgdir gno.land/r/acme/tasks/impl/v1 \
  -pkgpath gno.land/r/acme/tasks/impl/v1 $FLAGS you
gnokey maketx call $CALL -func Manage -args accept -args gno.land/r/acme/tasks/impl/v1 you
```

The data is not migrated, because it was never in v0 — it has been in the
permanent realm the whole time, and it reads the same before and after.

**If you break something, `accept` says so and refuses:**

```
Data: app: refusing a breaking upgrade to gno.land/r/acme/tasks/impl/v9:
      verb add: parameter text changed from string to int; verb count removed
      — use the accept-breaking verb to override
```

That is the schema earning its keep. Breaking means a verb disappears, a
parameter disappears or changes kind or position, a required parameter
appears, or a result kind changes. Additions are never breaking.

**If it turns out to be wrong at runtime**, roll back. The previous version
returns to serving and the bad one goes back to the pending set, so a fix can
be accepted without redeploying it:

```sh
gnokey maketx call $CALL -func Manage -args rollback -args "" you
```

Rollback restores code, not data. Anything the bad version wrote is still
written. Keep that in mind when deciding how much a new verb is allowed to
touch on its first day.

## Step 6: settle the authority

An address is right while you are the only one who cares. Once other people
depend on the app, it should not be a key on your laptop:

```sh
gnokey maketx call $CALL -func Manage -args govern -args gno.land/r/gov/dao you
```

The proxy implements no quorum, timelock or multisig on purpose — those belong
in a realm that can evolve its own rules. List both the old and new governance
realm during a handover, then narrow.

Verify before you lose access. A wrong path here locks the app permanently,
because nothing else can authorize a correction:

```sh
gnokey query vm/qeval -data 'gno.land/r/acme/tasks.Authority()'
```

## Step 7: stop being upgradeable

```sh
gnokey maketx call $CALL -func Manage -args freeze -args "" you
```

There is no unfreeze. The live handler keeps serving, every path to replace it
closes — including for the authority — and the storage the rollback history
was holding is refunded.

This is not a formality. Until it runs, every realm that imports yours is
trusting your authority rather than your code, and gno's interrealm spec is
explicit that two mutable realms cannot export trust between them. Freezing is
how an application graduates into something others can build on.

Do not skip there while you still have bugs; do not stay upgradeable once the
realm matters and has stopped changing.
