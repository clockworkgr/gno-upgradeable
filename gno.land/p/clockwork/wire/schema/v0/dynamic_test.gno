package schema

import "testing"

func TestDynamicRoundTrip(t *testing.T) {
	s, err := Parse(orderIDL)
	if err != nil || s.Validate() != nil {
		t.Fatal("schema")
	}
	in := map[string]any{
		"buyer": address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5"),
		"id":    uint64(9001),
		"items": []any{
			map[string]any{"price": int64(1999), "qty": uint64(3), "sku": "WIDGET-001"},
		},
		"note": "hello, world",
		"paid": true,
		"tags": []any{"a", "b"},
	}
	b, err := s.Encode("Order", in)
	if err != nil {
		t.Fatal(err)
	}
	out, err := s.Decode("Order", b)
	if err != nil {
		t.Fatal(err)
	}
	if out["id"].(uint64) != 9001 || out["note"].(string) != "hello, world" || !out["paid"].(bool) {
		t.Error("scalars")
	}
	items := out["items"].([]any)
	if len(items) != 1 || items[0].(map[string]any)["sku"].(string) != "WIDGET-001" {
		t.Errorf("items: %v", items)
	}
	if len(out["tags"].([]any)) != 2 {
		t.Error("tags")
	}
}

func TestDynamicMissingFieldRejected(t *testing.T) {
	s, _ := Parse("message P {\n a int\n b string\n}\n")
	_, err := s.Encode("P", map[string]any{"a": int64(1)}) // b missing
	if err == nil {
		t.Error("expected a missing-field error")
	}
}

func TestDynamicWrongTypeRejected(t *testing.T) {
	s, _ := Parse("message P {\n a int\n}\n")
	_, err := s.Encode("P", map[string]any{"a": "not an int"})
	if err == nil {
		t.Error("expected a type error")
	}
}
