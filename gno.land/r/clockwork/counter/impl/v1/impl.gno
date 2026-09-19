// Package impl is the second implementation of gno.land/r/clockwork/counter.
//
// It fixes v0's missing floor: the count no longer goes negative. The count
// itself is not migrated, because it was never here -- it has been in the
// counter realm the whole time, and accepting this version leaves it exactly
// where v0 left it.
//
// What is new is clamped, below. State a later version needs and earlier
// ones did not have goes in the version that needs it: the counter realm's
// own fields are as immutable as its code, so they cannot be extended after
// the fact. The cost is that this counter starts at zero here, and that a
// rollback to v0 leaves it behind rather than reverting it.
package impl

import (
	"strconv"

	"gno.land/r/clockwork/counter"
)

type counterImpl struct {
	clamped int64
}

var instance = &counterImpl{}

// Increment adds delta, refusing to take the count below zero.
//
// The write to c.clamped persists in this realm, not in the counter realm:
// the method is declared here, so it runs with this realm's storage context
// even though the counter realm is what called it.
func (c *counterImpl) Increment(_ int, rlm realm, delta int64) int64 {
	st := counter.Store(0, rlm)
	next := st.Count() + delta
	if next < 0 {
		c.clamped++
		next = 0
	}
	st.Set(next)
	return next
}

func (c *counterImpl) Describe(_ int, rlm realm) string {
	return "Running `impl/v1`: clamps at zero (" +
		strconv.FormatInt(c.clamped, 10) + " so far)."
}

// Instance returns the implementation object, for a caller that would rather
// register it explicitly -- a governance realm assembling an upgrade, say --
// than rely on this realm's init having done it.
func Instance() counter.Counter { return instance }

func init(cur realm) {
	counter.Register(cross(cur), instance)
}
