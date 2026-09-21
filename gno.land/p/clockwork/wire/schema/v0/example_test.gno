package schema_test

import (
	"fmt"

	"gno.land/p/clockwork/wire/schema/v0"
)

func Example() {
	s, err := schema.Parse(`
message Point {
  y int
  x int
}`)
	if err != nil {
		panic(err)
	}

	// Fields serialize in sorted order (x before y), regardless of how they
	// were written.
	b, _ := s.Encode("Point", map[string]any{"x": int64(3), "y": int64(7)})
	v, _ := s.Decode("Point", b)

	fmt.Println(s.String())
	fmt.Println("x:", v["x"], "y:", v["y"])
	// Output:
	// message Point {
	//   x int
	//   y int
	// }
	//
	// x: 3 y: 7
}
