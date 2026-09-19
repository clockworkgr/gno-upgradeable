package upgradeable

import "strings"

// Authority decides who may change what a [Proxy] points at.
//
// It is handed the identity of the caller -- the realm that crossed into the
// realm holding the Proxy. When a transaction is sent straight to that realm
// the caller is a user: pkgPath is empty and addr is the signer. When the
// call arrives through another realm, say a DAO executing a proposal, pkgPath
// names that realm and addr is the realm's own address.
//
// Both halves are passed because the two authorization styles on gno.land
// read different ones: an owner check compares addresses, a governance check
// compares realm paths. An implementation must read the half it means and
// ignore the other. In particular an empty pkgPath is not a realm -- it is
// every user call -- so a path check must reject it explicitly.
type Authority interface {
	Authorized(addr address, pkgPath string) bool
	String() string
}

// AddrAuthority authorizes exactly one address: the signer of a direct call,
// or a realm acting at that address.
type AddrAuthority struct {
	addr address
}

// NewAddrAuthority returns an Authority holding addr.
func NewAddrAuthority(addr address) *AddrAuthority {
	if !addr.IsValid() {
		panic(ErrBadAddress)
	}
	return &AddrAuthority{addr: addr}
}

func (a *AddrAuthority) Authorized(addr address, _ string) bool {
	return a != nil && addr.IsValid() && addr == a.addr
}

// Address returns the authorized address.
func (a *AddrAuthority) Address() address {
	if a == nil {
		return ""
	}
	return a.addr
}

func (a *AddrAuthority) String() string {
	if a == nil {
		return "addr:<nil>"
	}
	return "addr:" + a.addr.String()
}

// RealmAuthority authorizes a fixed set of realm paths, the shape r/gov/dao
// uses: a governance realm executes the upgrade, and the proxy recognizes it
// by the path it was deployed at rather than by an address.
//
// More than one path is allowed so that authority can be moved without a gap:
// list both the old and the new governance realm, let the new one take over,
// then narrow the list.
type RealmAuthority struct {
	paths []string
}

// NewRealmAuthority returns an Authority holding paths. It panics on an empty
// list rather than authorizing nobody, and on a blank or padded entry rather
// than storing one that can never match a caller -- or, for a blank one,
// matches every user call.
func NewRealmAuthority(paths ...string) *RealmAuthority {
	if len(paths) == 0 {
		panic(ErrNoAuthority)
	}
	out := make([]string, 0, len(paths))
	for _, p := range paths {
		if p == "" || p != strings.TrimSpace(p) {
			panic(ErrBadRealmPath)
		}
		out = append(out, p)
	}
	return &RealmAuthority{paths: out}
}

func (a *RealmAuthority) Authorized(_ address, pkgPath string) bool {
	if a == nil || pkgPath == "" {
		return false
	}
	for _, p := range a.paths {
		if p == pkgPath {
			return true
		}
	}
	return false
}

// Paths returns a copy of the authorized realm paths.
func (a *RealmAuthority) Paths() []string {
	if a == nil {
		return nil
	}
	dup := make([]string, len(a.paths))
	copy(dup, a.paths)
	return dup
}

func (a *RealmAuthority) String() string {
	if a == nil {
		return "realms:<nil>"
	}
	return "realms:" + strings.Join(a.paths, ",")
}

// AnyOf authorizes a caller that any of its members authorizes. It is the
// handover shape for the common case: hold an address authority while you are
// still deploying, add the governance realm, drop the address later.
type AnyOf struct {
	auths []Authority
}

// NewAnyOf returns an Authority satisfied by any of auths. It panics on an
// empty list or a nil member, both of which would silently weaken or void
// the check.
func NewAnyOf(auths ...Authority) *AnyOf {
	if len(auths) == 0 {
		panic(ErrNoAuthority)
	}
	out := make([]Authority, 0, len(auths))
	for _, a := range auths {
		if a == nil {
			panic(ErrNoAuthority)
		}
		out = append(out, a)
	}
	return &AnyOf{auths: out}
}

func (a *AnyOf) Authorized(addr address, pkgPath string) bool {
	if a == nil {
		return false
	}
	for _, sub := range a.auths {
		if sub.Authorized(addr, pkgPath) {
			return true
		}
	}
	return false
}

func (a *AnyOf) String() string {
	if a == nil {
		return "anyOf:<nil>"
	}
	parts := make([]string, 0, len(a.auths))
	for _, sub := range a.auths {
		parts = append(parts, sub.String())
	}
	return "anyOf(" + strings.Join(parts, " ") + ")"
}
