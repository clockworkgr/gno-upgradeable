package orderpb_test

import (
	"testing"

	"gno.land/p/clockwork/orderpb/v0"
	"gno.land/p/clockwork/wire/schema/v0"
)

const idl = `
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

// The whole point of the schema: generated code and the dynamic codec, both
// driven by the same schema, must produce identical bytes. If they ever
// diverge, the schema is not actually pinning the layout.
func TestGeneratedEqualsDynamic(t *testing.T) {
	s, err := schema.Parse(idl)
	if err != nil {
		t.Fatal(err)
	}

	buyer := address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5")

	gen := orderpb.Order{
		Buyer: buyer,
		Id:    9001,
		Items: []orderpb.Item{
			{Price: 1999, Qty: 3, Sku: "WIDGET-001"},
			{Price: 4999, Qty: 1, Sku: "GADGET-XL"},
		},
		Note: "leave at the back door; ring twice",
		Paid: true,
		Tags: []string{"priority", "fragile"},
	}.MarshalWire()

	dyn, err := s.Encode("Order", map[string]any{
		"buyer": buyer,
		"id":    uint64(9001),
		"items": []any{
			map[string]any{"price": int64(1999), "qty": uint64(3), "sku": "WIDGET-001"},
			map[string]any{"price": int64(4999), "qty": uint64(1), "sku": "GADGET-XL"},
		},
		"note": "leave at the back door; ring twice",
		"paid": true,
		"tags": []any{"priority", "fragile"},
	})
	if err != nil {
		t.Fatal(err)
	}

	if string(gen) != string(dyn) {
		t.Errorf("generated and dynamic bytes differ (%d vs %d)", len(gen), len(dyn))
	}
}
