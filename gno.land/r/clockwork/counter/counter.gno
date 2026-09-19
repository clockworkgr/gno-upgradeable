// Package counter is a worked example of a realm whose path is permanent and
// whose behavior is not.
//
// gno.land/r/clockwork/counter can never be deployed over. What changes is
// which object it calls: implementations live in their own realms under
// impl/, register themselves from their own init, and start serving once the
// authority accepts them. The count itself never moves -- it is declared
// here, at the path that cannot change, which is what makes an upgrade a
// change of behavior rather than a loss of data.
//
// See the README for the deploy-and-upgrade sequence.
package counter

import (
	"strconv"
	"strings"

	"gno.land/p/clockwork/upgradeable/v0"
)

// Counter is the behavior this realm promises. It is declared here rather
// than in an implementation realm so that every version agrees on one type
// identity, and so that the contract outlives any of them: this file is
// immutable, which is exactly the property an interface other realms depend
// on needs to have.
//
// The methods take (_ int, rlm realm) -- the non-crossing form. The value
// threaded in is this realm's own cur, so an implementation calling Store
// below is seen by it as this realm rather than as itself. That is what lets
// one state object serve every version, and it is the convention r/gov/dao
// uses for its own DAO interface.
type Counter interface {
	// Increment applies delta to the shared state and returns the new value.
	Increment(_ int, rlm realm, delta int64) int64

	// Describe returns a markdown line naming the implementation, so Render
	// shows which code answered.
	Describe(_ int, rlm realm) string
}

// Admin is the address that may accept, roll back, or freeze an upgrade.
//
// It is written here rather than captured from whoever signs the deployment,
// because this file is what a reviewer reads before deciding whether to trust
// the realm -- and an authority that is only decided at deploy time is not
// something they can read. Every gno.land realm that ships with an owner does
// it this way.
//
// Replace it with your own address before deploying; TransferAuthority moves
// it afterwards. The value here is the standard test1 account, so that the
// tests and the local-chain walkthrough in the README work unedited.
const Admin = address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5")

var (
	proxy    *upgradeable.Proxy
	selfPath string
)

func init(cur realm) {
	// Captured rather than written as a constant: Store compares against it
	// on every call, and a path that drifts from the deployment should fail
	// loudly at deploy time, not quietly at authorization time.
	selfPath = cur.PkgPath()

	// Hand this to a governance realm later with TransferAuthorityToRealms,
	// or end upgradeability altogether with Freeze.
	proxy = upgradeable.New(upgradeable.NewAddrAuthority(Admin))
}

// Increment is a permanent entry point. Its signature is part of what this
// realm promises; the code that answers it is not.
func Increment(cur realm, delta int64) int64 {
	return live().Increment(0, cur, delta)
}

// LiveImpl returns the live implementation as an untyped value.
//
// This is the one hook that lets this realm's API grow after it is frozen in
// place. A realm deployed later declares an interface of its own, asserts
// this value to it, and calls methods this file never named -- and an
// implementation accepted later can satisfy that interface. Nothing here has
// to anticipate what the interface will be.
//
// It returns nil when nothing is live, so callers should check. Handing out
// the implementation is not a privilege escalation: the methods still need
// this realm's cur to reach any state, and Store decides that separately.
func LiveImpl() any {
	v, ok := proxy.TryImpl()
	if !ok {
		return nil
	}
	return v
}

// Count reads the state directly. Reads do not go through the
// implementation, so they keep working between an accepted upgrade and
// whatever the new version decides to do.
func Count() int64 {
	return count
}

// Register records the calling realm as a candidate implementation.
//
// An implementation realm calls this from its own init, so deploying the new
// version is what nominates it -- and the path recorded is read off the
// crossing frame, not taken as an argument, so it is the path the code
// actually lives at. Nothing is served until Accept runs.
func Register(cur realm, impl Counter) {
	proxy.Propose(0, cur, impl)
}

// Accept makes the candidate at pkgPath live. Authority only.
func Accept(cur realm, pkgPath string) {
	proxy.Accept(0, cur, pkgPath)
}

// Withdraw drops a candidate. Authority only, except that a realm may always
// drop its own.
func Withdraw(cur realm, pkgPath string) {
	proxy.Withdraw(0, cur, pkgPath)
}

// Rollback restores the previous implementation and returns the current one
// to the pending set. Authority only.
func Rollback(cur realm) {
	proxy.Rollback(0, cur)
}

// Forget drops the rollback history, and the storage it holds. Authority
// only.
func Forget(cur realm) {
	proxy.Forget(0, cur)
}

// Freeze ends upgradeability permanently. Authority only, and there is no
// way back -- which is the point: until this runs, no other realm can treat
// this one's behavior as fixed.
func Freeze(cur realm) {
	proxy.Freeze(0, cur)
}

// AddExtension permits another realm to act as this one -- to reach the state
// below and to serve entry points this realm never declared. Authority only.
func AddExtension(cur realm, pkgPath string) { proxy.AddExtension(0, cur, pkgPath) }

// DropExtension revokes one. Authority only.
func DropExtension(cur realm, pkgPath string) { proxy.DropExtension(0, cur, pkgPath) }

// Extensions lists the realms currently allowed to act as this one.
func Extensions() []string { return proxy.Extensions() }

// TransferAuthority hands the power to upgrade to another address.
func TransferAuthority(cur realm, newOwner address) {
	proxy.TransferAuthority(0, cur, upgradeable.NewAddrAuthority(newOwner))
}

// TransferAuthorityToRealms hands the power to upgrade to one or more
// governance realms, named by path. Comma-separated so it can be sent with
// gnokey; listing more than one lets authority move without a gap.
func TransferAuthorityToRealms(cur realm, csvPaths string) {
	parts := strings.Split(csvPaths, ",")
	paths := make([]string, 0, len(parts))
	for _, p := range parts {
		paths = append(paths, strings.TrimSpace(p))
	}
	proxy.TransferAuthority(0, cur, upgradeable.NewRealmAuthority(paths...))
}

// LivePath returns the realm path of the implementation currently serving.
func LivePath() string { return proxy.LivePath() }

// PendingPaths returns the candidate realm paths awaiting acceptance.
func PendingPaths() []string {
	out := []string{}
	for _, r := range proxy.Pending() {
		out = append(out, r.PkgPath())
	}
	return out
}

// HistoryPaths returns the implementations this realm has already served,
// oldest first.
func HistoryPaths() []string {
	out := []string{}
	for _, r := range proxy.History() {
		out = append(out, r.PkgPath())
	}
	return out
}

// Frozen reports whether upgradeability has ended.
func Frozen() bool { return proxy.Frozen() }

// Authority returns a human-readable description of who may upgrade.
func Authority() string { return proxy.Authority().String() }

// live returns the implementation currently serving.
func live() Counter {
	v, ok := proxy.TryImpl()
	if !ok {
		panic("counter: no implementation has been accepted yet")
	}
	c, ok := v.(Counter)
	if !ok {
		// Register only admits a Counter, so reaching this means the live
		// release predates a change to the interface -- which cannot happen
		// to a deployed realm, but is cheap to rule out.
		panic("counter: live implementation does not satisfy Counter")
	}
	return c
}

func Render(cur realm, _ string) string {
	var b strings.Builder
	b.WriteString("# counter\n\n")
	b.WriteString("Count: **" + strconv.FormatInt(count, 10) + "**\n\n")

	if path := proxy.LivePath(); path == "" {
		b.WriteString("_No implementation accepted yet._\n\n")
	} else {
		b.WriteString("Serving: [" + path + "](/" + strings.TrimPrefix(path, "gno.land/") + ")\n\n")
		b.WriteString(live().Describe(0, cur) + "\n\n")
	}

	b.WriteString("Authority: `" + proxy.Authority().String() + "`\n\n")
	if proxy.Frozen() {
		b.WriteString("**Frozen.** This realm can no longer be upgraded.\n")
		return b.String()
	}

	if exts := proxy.Extensions(); len(exts) > 0 {
		b.WriteString("## Extensions\n\nRealms permitted to act as this one:\n\n")
		for _, e := range exts {
			b.WriteString("- `" + e + "`\n")
		}
		b.WriteString("\n")
	}
	if pending := proxy.Pending(); len(pending) > 0 {
		b.WriteString("## Awaiting acceptance\n\n")
		for _, r := range pending {
			b.WriteString("- `" + r.PkgPath() + "` (registered at height " +
				strconv.FormatInt(r.Height(), 10) + ")\n")
		}
		b.WriteString("\n")
	}
	if past := proxy.History(); len(past) > 0 {
		b.WriteString("## Previously\n\n")
		for _, r := range past {
			b.WriteString("- `" + r.PkgPath() + "`\n")
		}
	}
	return b.String()
}
