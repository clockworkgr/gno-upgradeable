package wire_test

import (
	"fmt"

	"gno.land/p/clockwork/wire/v0"
)

// The call order is the schema: read the same types, in the same order, you
// wrote.
func Example() {
	payload := wire.NewWriter().
		Int(42).
		Str("rent, please"). // commas and quotes need no escaping
		Bool(true).
		Bytes()

	r := wire.NewReader(payload)
	amount := r.Int()
	memo := r.Str()
	urgent := r.Bool()
	if r.Err() != nil {
		panic(r.Err())
	}

	fmt.Println(amount, memo, urgent)
	// Output: 42 rent, please true
}
