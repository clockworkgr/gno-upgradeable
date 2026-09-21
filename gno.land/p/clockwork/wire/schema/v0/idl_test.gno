package schema

import "testing"

const orderIDL = `// an order and its line items
message Item {
  price int
  qty   uint
  sku   string
}

message Order {
  buyer address
  id    uint
  items []Item
  note  string
  paid  bool
  tags  []string
}
`

func TestParsePrintRoundTrip(t *testing.T) {
	s, err := Parse(orderIDL)
	if err != nil {
		t.Fatal(err)
	}
	if err := s.Validate(); err != nil {
		t.Fatal(err)
	}
	// print, re-parse, print again: must be stable, and comments/whitespace
	// normalize away.
	once := s.String()
	s2, err := Parse(once)
	if err != nil {
		t.Fatal(err)
	}
	if twice := s2.String(); twice != once {
		t.Errorf("not canonical:\n--- once ---\n%s\n--- twice ---\n%s", once, twice)
	}
}

// Declaration order must not matter: the same fields in any order print the
// same, because printing sorts them.
func TestOrderIndependence(t *testing.T) {
	a, _ := Parse("message M {\n a int\n b int\n c int\n}\n")
	b, _ := Parse("message M {\n c int\n a int\n b int\n}\n")
	if a.String() != b.String() {
		t.Errorf("field declaration order leaked into the schema:\n%s\nvs\n%s", a, b)
	}
}

func TestValidateCatches(t *testing.T) {
	cases := map[string]string{
		"unknown message":  "message A {\n x Nope\n}\n",
		"duplicate field":  "message A {\n x int\n x uint\n}\n",
		"cycle":            "message A {\n b B\n}\nmessage B {\n a A\n}\n",
	}
	for name, idl := range cases {
		s, err := Parse(idl)
		if err != nil {
			continue // some are parse-time; fine
		}
		if s.Validate() == nil {
			t.Errorf("%s: expected a validation error", name)
		}
	}
}

// A message may hold a list of itself: the list is length-delimited, so it is
// not a cycle.
func TestListRecursionAllowed(t *testing.T) {
	s, err := Parse("message Tree {\n kids []Tree\n label string\n}\n")
	if err != nil {
		t.Fatal(err)
	}
	if err := s.Validate(); err != nil {
		t.Errorf("a list of self should be allowed: %v", err)
	}
}
