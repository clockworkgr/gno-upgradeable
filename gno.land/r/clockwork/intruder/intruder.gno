// Package intruder exists to be refused.
//
// It is an ordinary realm that imports the counter realm -- which anyone may
// do, since counter is public -- and asks it for the state object that the
// live implementation is allowed to write. The counter realm hands that
// object out against a realm value rather than an address, so what stops this
// is not a list of who is blocked but the fact that this realm's cur carries
// its own path.
package intruder

import "gno.land/r/clockwork/counter"

// Steal tries to read the counter's state from outside. It aborts.
func Steal(cur realm) int64 {
	return counter.Store(0, cur).Count()
}

// Tamper tries to write it. It aborts too, one call earlier than you might
// expect: the refusal is in handing over the object, not in the write.
func Tamper(cur realm, v int64) {
	counter.Store(0, cur).Set(v)
}
