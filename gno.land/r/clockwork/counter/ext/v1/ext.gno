// Package ext adds an entry point to gno.land/r/clockwork/counter after that
// realm was deployed and could no longer be changed.
//
// The counter realm's exported functions are fixed: it will never have a
// Decrement. This realm does, and it is a real entry point -- users MsgCall
// gno.land/r/clockwork/counter/ext/v1.Decrement and it moves the same count,
// in the same realm, as counter.Increment does.
//
// Two things make that work, and both are ordinary Gno rather than anything
// the counter realm arranged in advance:
//
//  1. counter.LiveImpl() hands out the live implementation as `any`. The
//     interface below is declared HERE, so the assertion asks a question the
//     counter realm never had to anticipate. Satisfaction is structural.
//
//  2. counter's state accessor admits this realm because the authority
//     registered it with counter.AddExtension. Without that the assertion
//     still succeeds and the call still panics, one step later, at the state.
//
// So the API grew by one realm and one governance call, with the original
// realm unmodified and its own guarantees intact.
package ext

import "gno.land/r/clockwork/counter"

// Decrementer is what this realm needs an implementation to be. counter has
// never heard of it; impl/v2 satisfies it by coincidence of signature.
type Decrementer interface {
	Decrement(_ int, rlm realm, delta int64) int64
}

// Decrement subtracts from the shared count.
//
// It panics under an implementation that predates it -- impl/v0 and impl/v1
// have no Decrement -- which is the honest failure: this entry point is only
// as available as the implementation currently serving.
func Decrement(cur realm, delta int64) int64 {
	v := counter.LiveImpl()
	if v == nil {
		panic("ext/v1: counter has no live implementation")
	}
	d, ok := v.(Decrementer)
	if !ok {
		panic("ext/v1: the live implementation does not support Decrement; " +
			"it is " + counter.LivePath())
	}
	return d.Decrement(0, cur, delta)
}

// Supported reports whether the live implementation can answer Decrement, so
// a caller can check before spending gas on a panic.
func Supported() bool {
	v := counter.LiveImpl()
	if v == nil {
		return false
	}
	_, ok := v.(Decrementer)
	return ok
}
