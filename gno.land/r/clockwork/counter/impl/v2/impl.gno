// Package impl is the third implementation of gno.land/r/clockwork/counter.
//
// It satisfies counter.Counter, as every implementation must. It also
// satisfies an interface the counter realm has never heard of, declared in
// gno.land/r/clockwork/counter/ext/v1 and deployed after it -- which is what
// lets a permanent realm answer a call its own source never named.
//
// Nothing here imports ext/v1. Interface satisfaction in Gno is structural,
// so the two only have to agree on a method signature.
package impl

import (
	"strconv"

	"gno.land/r/clockwork/counter"
)

type counterImpl struct {
	clamped int64
}

var instance = &counterImpl{}

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

// Decrement is the new operation. The counter realm cannot call it -- its
// Counter interface has no such method and never will -- but ext/v1 can.
func (c *counterImpl) Decrement(_ int, rlm realm, delta int64) int64 {
	return c.Increment(0, rlm, -delta)
}

func (c *counterImpl) Describe(_ int, rlm realm) string {
	return "Running `impl/v2`: clamps at zero (" +
		strconv.FormatInt(c.clamped, 10) + " so far), and answers Decrement."
}

func Instance() counter.Counter { return instance }

func init(cur realm) {
	counter.Register(cross(cur), instance)
}
