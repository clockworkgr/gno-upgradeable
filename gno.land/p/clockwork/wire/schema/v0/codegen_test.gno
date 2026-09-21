package schema

import (
	"strings"
	"testing"
)

func TestGenerateStructure(t *testing.T) {
	s, err := Parse(orderIDL)
	if err != nil {
		t.Fatal(err)
	}
	out, err := GenerateGno(s, "orderpb")
	if err != nil {
		t.Fatal(err)
	}

	must := func(sub string) {
		if !strings.Contains(out, sub) {
			t.Errorf("generated code missing: %q", sub)
		}
	}

	// fields sorted in the struct
	buyer := strings.Index(out, "Buyer address")
	id := strings.Index(out, "Id    uint64")
	items := strings.Index(out, "Items []Item")
	if !(buyer < id && id < items) || buyer < 0 {
		t.Error("struct fields are not in sorted order")
	}
	// nested + list compose through helpers
	must("e.marshalTo(w)")
	must("m.Items = append(m.Items, readItem(r))")
	// the untrusted-count guard is generated
	must("if c > uint64(r.Remaining()) {")
	// public API
	must("func (m Order) MarshalWire() []byte")
	must("func UnmarshalOrder(b []byte) (Order, error)")
	// trailing-bytes strictness
	must("trailing bytes for Order")
}

func TestGenerateRejectsInvalidSchema(t *testing.T) {
	s, _ := Parse("message A {\n b B\n}\n") // B undefined
	if _, err := GenerateGno(s, "x"); err == nil {
		t.Error("expected generation to refuse an invalid schema")
	}
}
