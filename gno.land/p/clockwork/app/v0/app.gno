// Package app is an upgradeable realm in a handful of forwarding functions.
//
// It answers a narrower question than [upgradeable] does. That package gives
// you a proxy and leaves the shape of your realm to you: your interface, your
// state, your entry points, all of them permanent. This one makes a different
// trade — it fixes the shape once, generically, so that nothing about your
// application is permanent except the path.
//
//	package todo
//
//	import "gno.land/p/clockwork/app/v0"
//
//	const Admin = address("g1…")
//
//	var a = app.New(app.Owner(Admin))
//
//	func init(cur realm)                              { a.Bind(0, cur) }
//	func Call(cur realm, verb, payload string) string { return a.Call(0, cur, verb, payload) }
//	func Register(cur realm, h app.Handler)           { a.Register(0, cur, h) }
//	func Manage(cur realm, verb, arg string) string   { return a.Admin(0, cur, verb, arg) }
//	func Store(_ int, rlm realm) *app.Store           { return a.Store(0, rlm) }
//	func Render(path string) string                   { return a.Render(path) }
//
// That realm never needs to change again. Its API is [Handler]'s verb set,
// which is data; its state is a [Store], whose keys are data. A later
// implementation adds verbs and keys freely, and callers reach them through
// the same Call.
//
// # Why the forwards cannot be avoided
//
// Those six lines are the irreducible minimum. A `p/` package cannot declare
// crossing functions, and `MsgCall` reaches a function by name at a realm
// path — so every entry point a user calls has to be declared in your realm.
// What a pure package can do is make each one a single forward, which is what
// the methods below are shaped for. Copy the block; only Admin changes.
//
// # What you give up
//
// Typed entry points. `Call(cur, "transfer", payload)` is one signature
// forever, so gnoweb shows one function, arguments are strings you encode
// yourself, and a misspelled verb is a runtime panic rather than a
// compile-time error. If your API is small and you can name it now, declare it
// with [upgradeable] and keep your types.
//
// The two compose: an app realm can carry hand-written typed entry points
// beside Call, forwarding to Proxy() for dispatch. Start generic, add typed
// entry points for the verbs that settle.
package app

import (
	"errors"
	"strconv"
	"strings"

	"gno.land/p/clockwork/upgradeable/v0"
)

var (
	// ErrNoHandler is raised when the app has no accepted implementation.
	ErrNoHandler = errors.New("app: no handler is live")

	// ErrNotAHandler is raised when the live implementation does not satisfy
	// Handler. Register admits only a Handler, so this is unreachable in
	// practice and cheap to rule out.
	ErrNotAHandler = errors.New("app: live implementation does not satisfy Handler")

	// ErrStaleRealm is raised when the threaded realm value is not the
	// caller's live cur.
	ErrStaleRealm = errors.New("app: realm value is not the caller's live cur")

	// ErrNotBound is raised when Bind has not run, so the app does not know
	// its own path and cannot tell its callers apart.
	ErrNotBound = errors.New("app: Bind has not been called from init")

	// ErrForbidden is raised when a realm that is neither the app nor a
	// registered extension asks for the store.
	ErrForbidden = errors.New("app: store is not reachable from this realm")

	// ErrUnknownVerb is raised by Admin for a verb it does not implement.
	ErrUnknownVerb = errors.New("app: unknown admin verb")

	// ErrNoSchema is raised when a handler declares no verbs. An app whose
	// API cannot be enumerated is the thing this package exists to avoid.
	ErrNoSchema = errors.New("app: a handler must declare at least one verb")
)

// Handler is what an implementation realm implements.
//
// Two methods. [Handler.Schema] declares the API as data — a verb set rather
// than a method set, which is what lets it grow past the realm that serves it.
// [Handler.Handle] answers one call, having been handed a payload the app has
// already decoded and checked against that declaration.
//
// Panic to fail; panics cross the realm boundary and abort the transaction.
type Handler interface {
	// Schema declares the verbs this handler answers. It must not be nil or
	// empty, and it should be a package-level value rather than rebuilt per
	// call — the app reads it on every dispatch.
	Schema() *Schema

	// Handle answers args.Verb(). Every declared parameter is present and
	// parses as its kind by the time this runs, so the accessors on Args do
	// not return errors.
	Handle(_ int, rlm realm, args *Args) string
}

// App is the proxy, the state and the dispatch, in one object to hold at
// realm level.
type App struct {
	proxy *upgradeable.Proxy
	data  *kv
	self  string
}

// Owner returns an authority for a single address. Re-exported so a realm
// using this package need not import [upgradeable] as well.
func Owner(addr address) upgradeable.Authority { return upgradeable.NewAddrAuthority(addr) }

// Governed returns an authority for one or more governance realm paths.
func Governed(paths ...string) upgradeable.Authority {
	return upgradeable.NewRealmAuthority(paths...)
}

// New returns an App whose implementations must be deployed under the app
// realm's own path.
func New(auth upgradeable.Authority) *App {
	return &App{proxy: upgradeable.New(auth), data: newKV()}
}

// NewOpen returns an App that accepts implementations from any realm. The
// authority still decides which one serves.
func NewOpen(auth upgradeable.Authority) *App {
	return &App{proxy: upgradeable.NewOpen(auth), data: newKV()}
}

// Bind teaches the app its own path, which is what every later caller check
// compares against. Call it once, from your realm's init:
//
//	func init(cur realm) { a.Bind(0, cur) }
//
// It is separate from New because a package-level var initializer runs before
// there is a realm frame to read the path from.
func (a *App) Bind(_ int, rlm realm) {
	if !rlm.IsCurrent() {
		panic(ErrStaleRealm)
	}
	a.self = rlm.PkgPath()
}

// Proxy exposes the underlying proxy, for realms that want typed entry points
// beside Call or their own Render.
func (a *App) Proxy() *upgradeable.Proxy { return a.proxy }

// The inspection surface. Render shows all of it as a page; these are the
// same facts as discrete values, which is what an operator wants from
// vm/qeval and what a monitor wants to poll.

// LivePath returns the realm path of the handler currently serving, or "".
func (a *App) LivePath() string { return a.proxy.LivePath() }

// PendingPaths returns the candidate handler paths awaiting acceptance.
func (a *App) PendingPaths() []string { return paths(a.proxy.Pending()) }

// HistoryPaths returns the handlers already served, oldest first. A non-empty
// result is what makes rollback available.
func (a *App) HistoryPaths() []string { return paths(a.proxy.History()) }

// Extensions returns the realms permitted to act as this app.
func (a *App) Extensions() []string { return a.proxy.Extensions() }

// Frozen reports whether upgradeability has ended.
func (a *App) Frozen() bool { return a.proxy.Frozen() }

// Authority describes who may upgrade.
func (a *App) Authority() string { return a.proxy.Authority().String() }

func paths(rs []upgradeable.Release) []string {
	out := []string{}
	for _, r := range rs {
		out = append(out, r.PkgPath())
	}
	return out
}

// handler returns the live handler.
func (a *App) handler() Handler {
	v, ok := a.proxy.TryImpl()
	if !ok {
		panic(ErrNoHandler)
	}
	h, ok := v.(Handler)
	if !ok {
		panic(ErrNotAHandler)
	}
	return h
}

// Call decodes payload against the live handler's declaration for verb, and
// dispatches.
//
// An unknown verb, a payload with the wrong number of fields, or a field that
// does not parse as its declared kind are all refused here, before the handler
// runs, with a message naming the verb and its signature.
func (a *App) Call(_ int, rlm realm, verb string, payload string) string {
	h := a.handler()
	sc := h.Schema()
	v, ok := sc.Lookup(verb)
	if !ok {
		panic(errors.New("app: unknown verb " + strconv.Quote(verb) +
			"; this app answers " + strings.Join(sc.Names(), ", ")))
	}
	args, err := decode(v, payload)
	if err != nil {
		panic(err)
	}
	return h.Handle(0, rlm, args)
}

// Schema returns the live handler's declaration, or nil if nothing is live.
func (a *App) Schema() *Schema {
	v, ok := a.proxy.TryImpl()
	if !ok {
		return nil
	}
	h, ok := v.(Handler)
	if !ok {
		return nil
	}
	return h.Schema()
}

// Verbs enumerates the API. This is the query a caller makes first.
func (a *App) Verbs() []string { return a.Schema().Names() }

// Signature returns one verb's declaration, or "" if it is not answered.
func (a *App) Signature(verb string) string { return a.Schema().Signature(verb) }

// SchemaJSON renders the API for tooling: enough to build a form without
// reading any Gno source.
func (a *App) SchemaJSON() string { return a.Schema().JSON() }

// Supports reports whether the live handler answers verb.
func (a *App) Supports(verb string) bool {
	_, ok := a.Schema().Lookup(verb)
	return ok
}

// Register nominates the calling realm's handler. Forward it from your realm
// and call it from the implementation's init.
//
// A handler that declares no verbs is refused here rather than at first call:
// an app whose API cannot be enumerated is the thing this package exists to
// avoid.
func (a *App) Register(_ int, rlm realm, h Handler) {
	if h == nil || len(h.Schema().Names()) == 0 {
		panic(ErrNoSchema)
	}
	a.proxy.Propose(0, rlm, h)
}

// candidate returns the registered handler at pkgPath.
func (a *App) candidate(pkgPath string) (Handler, bool) {
	for _, r := range a.proxy.Pending() {
		if r.PkgPath() == pkgPath {
			h, ok := r.Impl().(Handler)
			return h, ok
		}
	}
	return nil, false
}

// accept promotes a candidate, refusing an upgrade that would break callers
// unless force is set.
//
// This is the check a verb-dispatch API cannot have without a schema. Without
// it, a handler that quietly drops a verb its predecessor served is accepted
// happily and callers find out at runtime. With it, the drop is named before
// the upgrade lands.
func (a *App) accept(_ int, rlm realm, pkgPath string, force bool) {
	a.proxy.AssertAuthorized(0, rlm)
	next, ok := a.candidate(pkgPath)
	if ok && !force {
		if breaks := next.Schema().Diff(a.Schema()); len(breaks) > 0 {
			panic(errors.New("app: refusing a breaking upgrade to " + pkgPath +
				": " + strings.Join(breaks, "; ") +
				" — use the accept-breaking verb to override"))
		}
	}
	a.proxy.Accept(0, rlm, pkgPath)
}

// Store hands out a [Store] accessor to code running on this app's cur: the
// live handler, and any realm the authority has registered as an extension.
//
// A realm holding a perfectly valid cur of its own is refused, because that
// cur carries its own path. And because the accessor carries the cur and
// re-checks it on every operation, the grant cannot outlive this call frame:
// a handler that stashes the accessor aborts the transaction (a realm value
// cannot be persisted), so rollback and freeze can no longer be undermined by
// a captured reference. See [Store].
func (a *App) Store(_ int, rlm realm) *Store {
	a.access(0, rlm) // gate at acquisition, for an immediate, clear refusal
	return &Store{app: a, rlm: rlm}
}

// access validates that rlm may reach the data and returns it. It runs at
// acquisition and again on every Store operation, so a stale or foreign rlm
// is refused every time, not just when the accessor is minted -- which is the
// teeth behind Store being a per-call capability.
func (a *App) access(_ int, rlm realm) *kv {
	if !rlm.IsCurrent() {
		panic(ErrStaleRealm)
	}
	if a.self == "" {
		panic(ErrNotBound)
	}
	if c := rlm.PkgPath(); c != a.self && !a.proxy.IsExtension(c) {
		panic(errors.New(ErrForbidden.Error() + ": " + c))
	}
	return a.data
}

// Admin is the whole governance surface behind one entry point, so a realm
// using this package declares one function instead of one per governance
// action.
//
//	accept <path>     make a registered candidate live, unless its schema
//	                  would break a caller of the one it replaces
//	accept-breaking <path>
//	                  the same, allowing a breaking schema change
//	withdraw <path>   drop a candidate
//	rollback          restore the previous handler
//	forget            drop the rollback history
//	freeze            end upgradeability, permanently
//	extend <path>     let another realm act as this one
//	unextend <path>   revoke that
//	owner <address>   hand authority to an address
//	govern <paths>    hand authority to governance realms (comma-separated)
//
// Every one of them is authority-gated by the proxy, except that a realm may
// always withdraw its own candidate. Returns "ok", or panics.
func (a *App) Admin(_ int, rlm realm, verb string, arg string) string {
	switch verb {
	case "accept":
		a.accept(0, rlm, arg, false)
	case "accept-breaking":
		a.accept(0, rlm, arg, true)
	case "withdraw":
		a.proxy.Withdraw(0, rlm, arg)
	case "rollback":
		a.proxy.Rollback(0, rlm)
	case "forget":
		a.proxy.Forget(0, rlm)
	case "freeze":
		a.proxy.Freeze(0, rlm)
	case "extend":
		a.proxy.AddExtension(0, rlm, arg)
	case "unextend":
		a.proxy.DropExtension(0, rlm, arg)
	case "owner":
		a.proxy.TransferAuthority(0, rlm, Owner(address(arg)))
	case "govern":
		parts := strings.Split(arg, ",")
		paths := make([]string, 0, len(parts))
		for _, p := range parts {
			paths = append(paths, strings.TrimSpace(p))
		}
		a.proxy.TransferAuthority(0, rlm, Governed(paths...))
	default:
		panic(errors.New(ErrUnknownVerb.Error() + ": " + verb))
	}
	return "ok"
}

// Render is a gnoweb page describing the app's current wiring: what serves,
// what could, what it used to, who decides, and how much state there is.
func (a *App) Render(_ string) string {
	var b strings.Builder
	b.WriteString("# " + a.self + "\n\n")

	if path := a.proxy.LivePath(); path == "" {
		b.WriteString("_No handler accepted yet._\n\n")
	} else {
		b.WriteString("Serving: `" + path + "`\n\n")
	}
	b.WriteString("State: **" + strconv.Itoa(a.data.length()) + "** keys\n\n")
	b.WriteString("Authority: `" + a.proxy.Authority().String() + "`\n\n")

	if sc := a.Schema(); sc != nil {
		b.WriteString("## API\n\n" + sc.Markdown() + "\n")
	}

	if a.proxy.Frozen() {
		b.WriteString("**Frozen.** The handler can no longer be replaced.\n\n")
	}
	writeList(&b, "Extensions", a.proxy.Extensions())
	writeReleases(&b, "Awaiting acceptance", a.proxy.Pending())
	writeReleases(&b, "Previously", a.proxy.History())
	return b.String()
}

func writeList(b *strings.Builder, title string, items []string) {
	if len(items) == 0 {
		return
	}
	b.WriteString("## " + title + "\n\n")
	for _, s := range items {
		b.WriteString("- `" + s + "`\n")
	}
	b.WriteString("\n")
}

func writeReleases(b *strings.Builder, title string, rs []upgradeable.Release) {
	if len(rs) == 0 {
		return
	}
	b.WriteString("## " + title + "\n\n")
	for _, r := range rs {
		b.WriteString("- `" + r.PkgPath() + "` (height " +
			strconv.FormatInt(r.Height(), 10) + ")\n")
	}
	b.WriteString("\n")
}
