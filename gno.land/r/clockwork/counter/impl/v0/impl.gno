// Package impl is the first implementation of gno.land/r/clockwork/counter.
//
// It holds no state of its own. The count lives in the counter realm, which
// is what lets this whole realm be replaced without anyone losing anything.
package impl

import "gno.land/r/clockwork/counter"

type counterImpl struct{}

var instance = &counterImpl{}

// Increment adds delta to the shared state. It does not check the sign,
// which is the bug v1 exists to fix.
func (c *counterImpl) Increment(_ int, rlm realm, delta int64) int64 {
	return counter.Store(0, rlm).Add(delta)
}

func (c *counterImpl) Describe(_ int, rlm realm) string {
	return "Running `impl/v0`: applies the delta as given, including below zero."
}

// init registers this realm as a candidate. Deploying it is the nomination;
// it serves nothing until the counter realm's authority accepts it.
//
// cross(cur) enters counter.Register, so inside it cur.Previous() is this
// realm -- which is how the counter realm learns the path to file the
// candidate under without being told.
// Instance returns the implementation object, for a caller that would rather
// register it explicitly -- a governance realm assembling an upgrade, say --
// than rely on this realm's init having done it.
func Instance() counter.Counter { return instance }

func init(cur realm) {
	counter.Register(cross(cur), instance)
}
