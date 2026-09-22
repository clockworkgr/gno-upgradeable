// Package upgradeable lets a realm at a permanent path serve behavior that
// can change.
//
// A gno.land package path is immutable. The VM keeper refuses MsgAddPackage
// at a path that already holds a package, and the one exception -- private
// = true in gnomod.toml -- buys redeployability by giving up importability,
// and starts the realm's globals over from nothing besides. So a realm other
// people import cannot have its code replaced. What it can do is decide at
// call time which object it calls, and that object can live in a realm
// deployed years later. There is no delegatecall here and imports resolve
// statically: the indirection is an ordinary interface value, handed over by
// the realm that implements it.
//
// [Proxy] is the bookkeeping for that. It holds the one live implementation,
// the candidates waiting to replace it, and the ones it used to be, with an
// [Authority] deciding who may move between them. What it deliberately does
// not hold is your state. State belongs in the realm at the permanent path,
// or in a realm of its own, so that replacing an implementation does not
// touch it -- see the counter example under r/ for both halves.
//
// This is a p/ package on purpose. Pure packages can never be redeployed, so
// the rules below cannot be swapped out from under the realm that relies on
// them, which is exactly the property an upgrade mechanism has to have.
//
// # Threading cur
//
// Every authority-sensitive method takes (_ int, rlm realm): the caller
// threads its own cur as data instead of crossing into this package. The
// leading int keeps rlm out of first position, where it would declare a
// crossing function. rlm.Previous() is then the realm that crossed into the
// caller -- the user sending the transaction, the governance realm executing
// a proposal, or the implementation realm registering itself -- and
// rlm.IsCurrent() is what makes that unforgeable: a realm value cannot be
// persisted, and a stale capture fails the check.
package upgradeable

import (
	"chain"
	"chain/runtime"
	"strings"
)

// Event types emitted on every state change, so an indexer can reconstruct
// which code served which block without replaying the realm.
const (
	ProposeEvent   = "UpgradeProposed"
	WithdrawEvent  = "UpgradeWithdrawn"
	AcceptEvent    = "UpgradeAccepted"
	RollbackEvent  = "UpgradeRolledBack"
	ForgetEvent    = "UpgradeHistoryDropped"
	ExtendEvent    = "UpgradeExtensionAdded"
	UnextendEvent  = "UpgradeExtensionDropped"
	FreezeEvent    = "UpgradeFrozen"
	AuthorityEvent = "UpgradeAuthorityTransferred"
)

// Release is one implementation: the object, and the realm that authored it.
//
// PkgPath is read off the crossing frame at registration, never taken as an
// argument, so it names the realm the code actually lives at. That is what
// makes it worth reviewing before an upgrade is accepted, and what lets a
// state realm recognize the live implementation later.
//
// Release is returned by value. The proxy's own copy stays unreachable from
// outside, so a reader cannot rewrite history.
type Release struct {
	pkgPath string
	impl    any
	height  int64
}

// PkgPath returns the realm path the implementation was registered from.
func (r Release) PkgPath() string { return r.pkgPath }

// Impl returns the implementation object.
func (r Release) Impl() any { return r.impl }

// Height returns the block height at which the implementation registered.
func (r Release) Height() int64 { return r.height }

// IsZero reports whether r is the zero Release, which is what accessors
// return alongside a false ok.
func (r Release) IsZero() bool { return r.pkgPath == "" }

// Proxy holds the live implementation and the bookkeeping around replacing
// it. Keep one as a realm-level variable; it persists with the realm.
type Proxy struct {
	auth    Authority
	live    *Release
	pending []*Release // kept sorted by pkgPath
	past     []*Release
	exts     []string // kept sorted; realms allowed to act as this one
	frozen   bool
	nested   bool
}

// New returns a Proxy whose candidates must register from a realm nested
// under the realm holding it: gno.land/r/you/app/impl/v1 under
// gno.land/r/you/app. Deploying under that prefix needs your namespace, so
// the pending set cannot be filled by strangers.
//
// It panics on a nil authority. Upgradeability with no authority is not
// "nobody can upgrade" -- to reach that, Freeze.
func New(auth Authority) *Proxy {
	return newProxy(auth, true)
}

// NewOpen is New without the nesting rule: any deployed realm may register a
// candidate and the authority alone decides. Use it when implementations
// come from outside your namespace. The cost is that anyone can add entries
// to the pending set, which lives in your realm's storage; Withdraw clears
// them.
func NewOpen(auth Authority) *Proxy {
	return newProxy(auth, false)
}

func newProxy(auth Authority, nested bool) *Proxy {
	if auth == nil {
		panic(ErrNoAuthority)
	}
	return &Proxy{
		auth:   auth,
		nested: nested,
	}
}

// Impl returns the live implementation, and panics with ErrNoImpl if nothing
// has been accepted yet. Realms call this on every request, so the panic is
// the honest answer: a proxy with no implementation has no behavior to serve.
func (p *Proxy) Impl() any {
	if p.live == nil {
		panic(ErrNoImpl)
	}
	return p.live.impl
}

// TryImpl returns the live implementation and whether there is one, for
// callers that would rather render an empty page than fail the transaction.
func (p *Proxy) TryImpl() (any, bool) {
	if p.live == nil {
		return nil, false
	}
	return p.live.impl, true
}

// Live returns the live release.
func (p *Proxy) Live() (Release, bool) {
	if p.live == nil {
		return Release{}, false
	}
	return *p.live, true
}

// LivePath returns the realm path of the live implementation, or "" if there
// is none. A state realm that wants to grant write access to whichever
// implementation is current compares its caller against this.
func (p *Proxy) LivePath() string {
	if p.live == nil {
		return ""
	}
	return p.live.pkgPath
}

// Pending returns the registered candidates, ordered by path.
func (p *Proxy) Pending() []Release {
	out := make([]Release, 0, len(p.pending))
	for _, r := range p.pending {
		out = append(out, *r)
	}
	return out
}

// History returns the releases this proxy has already served, oldest first.
// It excludes the live one, and Forget empties it.
func (p *Proxy) History() []Release {
	out := make([]Release, 0, len(p.past))
	for _, r := range p.past {
		out = append(out, *r)
	}
	return out
}

// Frozen reports whether upgradeability has ended.
func (p *Proxy) Frozen() bool { return p.frozen }

// Authority returns the current authority.
func (p *Proxy) Authority() Authority { return p.auth }

// Extensions returns the realm paths allowed to act as the realm holding this
// proxy, in sorted order.
//
// A realm path is fixed, so the exported functions of the realm holding this
// proxy can never grow. What can grow is the set of OTHER realms permitted to
// run against its state: a realm deployed later declares an interface of its
// own, asserts the live implementation to it, and calls through. That is how
// an application adds an entry point it did not ship with. See the
// "extending a frozen API" pattern in the repository docs.
//
// The state accessor in the realm holding this proxy is what consults this --
// nothing here reaches into your state on its own.
func (p *Proxy) Extensions() []string {
	dup := make([]string, len(p.exts))
	copy(dup, p.exts)
	return dup
}

// IsExtension reports whether pkgPath may act as the realm holding this proxy.
// Call it from the state accessor, alongside the check for the realm's own
// path.
func (p *Proxy) IsExtension(pkgPath string) bool {
	if pkgPath == "" {
		return false // a user call is not a realm
	}
	for _, e := range p.exts {
		if e == pkgPath {
			return true
		}
	}
	return false
}

// AddExtension permits pkgPath to act as the realm holding this proxy.
//
// This grants the authority no power it did not have. An authority that can
// Accept an arbitrary implementation can already run arbitrary code against
// the state; naming a second realm that may do the same widens what is
// reachable, not who decides. It does widen the surface a reviewer has to
// read, which is why Extensions is public and Render should show it.
//
// Caller: the authority.
func (p *Proxy) AddExtension(_ int, rlm realm, pkgPath string) {
	p.assertMutable()
	p.assertAuthorized(0, rlm)
	if pkgPath == "" || pkgPath != strings.TrimSpace(pkgPath) {
		panic(ErrBadRealmPath)
	}
	if p.IsExtension(pkgPath) {
		return
	}
	at := len(p.exts)
	for i, e := range p.exts {
		if pkgPath < e {
			at = i
			break
		}
	}
	p.exts = append(p.exts, "")
	copy(p.exts[at+1:], p.exts[at:])
	p.exts[at] = pkgPath
	chain.Emit(ExtendEvent, "realm", pkgPath)
}

// DropExtension revokes pkgPath. The extension realm stays deployed and keeps
// answering calls; it just stops being able to reach the state, so whatever it
// exposed starts panicking rather than disappearing.
//
// Caller: the authority.
func (p *Proxy) DropExtension(_ int, rlm realm, pkgPath string) {
	p.assertMutable()
	p.assertAuthorized(0, rlm)
	for i, e := range p.exts {
		if e == pkgPath {
			p.exts = append(p.exts[:i], p.exts[i+1:]...)
			chain.Emit(UnextendEvent, "realm", pkgPath)
			return
		}
	}
	panic(ErrUnknownPath)
}

// AssertAuthorized panics unless rlm's caller is the authority. It exists for
// wrappers that do work of their own before delegating -- a schema check
// before Accept, say -- so that an unauthorized caller is refused for the
// right reason rather than tripping over the wrapper's own validation first.
func (p *Proxy) AssertAuthorized(_ int, rlm realm) { p.assertAuthorized(0, rlm) }

// Propose registers impl as a candidate, filed under the path of the realm
// that is calling.
//
// That path comes off the crossing frame rather than from an argument, and
// that is the point of the whole mechanism: a candidate cannot claim to have
// been authored by a path it does not occupy. Whoever accepts it is
// therefore accepting code they can go and read at that path, and a state
// realm that gates writes on LivePath is gating on the same authenticated
// string.
//
// The implementation realm calls this from its own init, so deploying the
// new version is what nominates it. Nothing is served until the authority
// accepts. Re-registering from the same realm replaces that candidate, which
// is the retry path after a failed deployment.
func (p *Proxy) Propose(_ int, rlm realm, impl any) {
	p.assertMutable()
	if !rlm.IsCurrent() {
		panic(ErrStaleRealm)
	}
	if impl == nil {
		panic(ErrNilImpl)
	}

	prev := rlm.Previous()
	from := prev.PkgPath()
	if from == "" || prev.IsEphemeral() {
		// A user call has no path to record at all. An ephemeral one does
		// have a path -- `gnokey maketx run` executes in /e/<addr>/run --
		// but it does not outlive the transaction, so filing a candidate
		// under it records a path that will never hold the code it claims.
		// The emptiness check alone does not catch that one.
		panic(ErrNotARealm)
	}
	if p.nested && !isNested(rlm.PkgPath(), from) {
		panic(ErrNotNested)
	}

	p.setPending(&Release{
		pkgPath: from,
		impl:    impl,
		height:  runtime.ChainHeight(),
	})
	chain.Emit(ProposeEvent, "impl", from)
}

// Withdraw drops a candidate. The authority may drop any; a realm may always
// drop its own, which is how a superseded candidate stops costing storage
// without the authority having to act.
func (p *Proxy) Withdraw(_ int, rlm realm, pkgPath string) {
	p.assertMutable()
	if !rlm.IsCurrent() {
		panic(ErrStaleRealm)
	}
	if rlm.Previous().PkgPath() != pkgPath {
		p.assertAuthorized(0, rlm)
	}
	if !p.removePending(pkgPath) {
		panic(ErrUnknownPath)
	}
	chain.Emit(WithdrawEvent, "impl", pkgPath)
}

// Accept makes the candidate at pkgPath the live implementation, and files
// the one it replaces in History.
//
// This is the upgrade. It is a separate transaction from the deployment that
// registered the candidate, by a separate principal, which is what gives the
// authority something reviewable to act on -- the same two-phase shape
// gno.land itself uses when a chain parks a submission until an approver
// enables it.
func (p *Proxy) Accept(_ int, rlm realm, pkgPath string) {
	p.assertMutable()
	p.assertAuthorized(0, rlm)

	i := p.findPending(pkgPath)
	if i < 0 {
		panic(ErrUnknownPath)
	}
	rel := p.pending[i]
	p.removePending(pkgPath)

	from := ""
	if p.live != nil {
		from = p.live.pkgPath
		p.past = append(p.past, p.live)
	}
	p.live = rel
	chain.Emit(AcceptEvent, "impl", pkgPath, "replaced", from)
}

// Rollback puts the previous release back in front, and returns the one it
// displaces to the pending set so a fixed version can be re-accepted without
// redeploying it.
//
// This is why History is kept: the release objects stay reachable, and
// reachable is the only form of "still deployed" that matters here. It costs
// storage, which is what Forget is for once a version has proven itself.
func (p *Proxy) Rollback(_ int, rlm realm) {
	p.assertMutable()
	p.assertAuthorized(0, rlm)

	n := len(p.past)
	if n == 0 {
		panic(ErrNoHistory)
	}
	prev := p.past[n-1]
	p.past = p.past[:n-1]

	from := ""
	if p.live != nil {
		from = p.live.pkgPath
		p.setPending(p.live)
	}
	p.live = prev
	chain.Emit(RollbackEvent, "impl", prev.pkgPath, "replaced", from)
}

// Forget drops the history, releasing the old implementations. Rollback
// stops working -- there is nothing to roll back to -- so this is the "the
// current version has proven itself" move, not routine cleanup.
func (p *Proxy) Forget(_ int, rlm realm) {
	p.assertMutable()
	p.assertAuthorized(0, rlm)
	dropped := len(p.past)
	p.past = nil
	chain.Emit(ForgetEvent, "dropped", itoa(dropped))
}

// TransferAuthority hands the power to upgrade to auth. It panics on nil:
// there is no way to leave a proxy upgradeable by nobody, because that state
// is indistinguishable from a mistake. Freeze says it on purpose.
func (p *Proxy) TransferAuthority(_ int, rlm realm, auth Authority) {
	p.assertMutable()
	p.assertAuthorized(0, rlm)
	if auth == nil {
		panic(ErrNoAuthority)
	}
	old := p.auth.String()
	p.auth = auth
	chain.Emit(AuthorityEvent, "from", old, "to", auth.String())
}

// Freeze ends upgradeability for good. The live implementation keeps serving
// and nothing can replace it: no unfreeze, by design, because a proxy that
// can be thawed has not actually given anything up. This is how a realm
// graduates from "we are still fixing it" to something other realms can
// build on -- an interrealm contract is only as trustworthy as the least
// mutable realm behind it.
//
// It refuses to freeze with nothing live, which would leave the realm
// permanently unable to answer a call.
//
// Freezing finalizes the extension set. Whatever is registered survives (the
// frozen implementation may depend on it), but afterwards nothing can be added
// and -- because Drop is a mutation too -- nothing can be dropped. So a
// registered extension keeps its access to the realm's state for good. Review
// the extensions before you freeze; you cannot revoke one after.
func (p *Proxy) Freeze(_ int, rlm realm) {
	p.assertMutable()
	p.assertAuthorized(0, rlm)
	if p.live == nil {
		panic(ErrNoImpl)
	}
	p.frozen = true
	p.pending = nil
	p.past = nil
	// Extensions are deliberately kept. They are reachable code that the
	// frozen implementation may depend on, and dropping them here would
	// break entry points that were working a block ago -- a freeze should
	// fix the realm's behavior, not change it.
	chain.Emit(FreezeEvent, "impl", p.live.pkgPath)
}

// isNested reports whether child is parent, or sits under it. The trailing
// separators are what keep gno.land/r/you/appliance from counting as nested
// under gno.land/r/you/app.
func isNested(parent, child string) bool {
	return strings.HasPrefix(child+"/", parent+"/")
}

// findPending returns the index of the candidate at pkgPath, or -1.
func (p *Proxy) findPending(pkgPath string) int {
	for i, r := range p.pending {
		if r.pkgPath == pkgPath {
			return i
		}
	}
	return -1
}

// setPending inserts rel, or replaces the candidate already at its path.
// The slice is kept sorted so Pending and any Render built on it read the
// same way on every node.
func (p *Proxy) setPending(rel *Release) {
	if i := p.findPending(rel.pkgPath); i >= 0 {
		p.pending[i] = rel
		return
	}
	at := len(p.pending)
	for i, r := range p.pending {
		if rel.pkgPath < r.pkgPath {
			at = i
			break
		}
	}
	p.pending = append(p.pending, nil)
	copy(p.pending[at+1:], p.pending[at:])
	p.pending[at] = rel
}

// removePending drops the candidate at pkgPath, reporting whether one was
// there.
func (p *Proxy) removePending(pkgPath string) bool {
	i := p.findPending(pkgPath)
	if i < 0 {
		return false
	}
	p.pending = append(p.pending[:i], p.pending[i+1:]...)
	return true
}

func (p *Proxy) assertMutable() {
	if p.frozen {
		panic(ErrFrozen)
	}
}

func (p *Proxy) assertAuthorized(_ int, rlm realm) {
	if !rlm.IsCurrent() {
		panic(ErrStaleRealm)
	}
	caller := rlm.Previous()
	if !p.auth.Authorized(caller.Address(), caller.PkgPath()) {
		panic(ErrUnauthorized)
	}
}

// itoa avoids pulling ufmt in for one event attribute.
func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var buf [20]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		buf[i] = '-'
	}
	return string(buf[i:])
}
