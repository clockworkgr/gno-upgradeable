package orderpb

import "testing"

// Proves the generated code compiles and round-trips, nesting and slices
// included.
func TestGeneratedRoundTrip(t *testing.T) {
	in := Order{
		Buyer: address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5"),
		Id:    9001,
		Items: []Item{
			{Price: 1999, Qty: 3, Sku: "WIDGET-001"},
			{Price: 4999, Qty: 1, Sku: "GADGET-XL"},
		},
		Note: "leave at the back door; ring twice",
		Paid: true,
		Tags: []string{"priority", "fragile"},
	}
	out, err := UnmarshalOrder(in.MarshalWire())
	if err != nil {
		t.Fatal(err)
	}
	if out.Buyer != in.Buyer || out.Id != in.Id || out.Note != in.Note || out.Paid != in.Paid {
		t.Error("scalar fields did not round-trip")
	}
	if len(out.Items) != 2 || out.Items[0].Sku != "WIDGET-001" || out.Items[1].Price != 4999 {
		t.Errorf("items did not round-trip: %v", out.Items)
	}
	if len(out.Tags) != 2 || out.Tags[1] != "fragile" {
		t.Errorf("tags did not round-trip: %v", out.Tags)
	}
}

func TestGeneratedEmptySlices(t *testing.T) {
	in := Order{Buyer: address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5"), Id: 1}
	out, err := UnmarshalOrder(in.MarshalWire())
	if err != nil {
		t.Fatal(err)
	}
	if len(out.Items) != 0 || len(out.Tags) != 0 {
		t.Error("empty slices should stay empty")
	}
}

func TestGeneratedRejectsTruncation(t *testing.T) {
	full := Order{
		Buyer: address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5"),
		Id:    1,
		Items: []Item{{Price: 1, Qty: 1, Sku: "x"}},
	}.MarshalWire()
	for cut := 0; cut < len(full); cut++ {
		if _, err := UnmarshalOrder(full[:cut]); err == nil {
			t.Errorf("cut %d: expected an error", cut)
		}
	}
}
