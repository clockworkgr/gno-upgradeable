package wire_test

import (
	"errors"
	"fmt"

	"gno.land/p/clockwork/wire/v0"
)

// ---------- simple: a flat struct ----------

type Transfer struct {
	To     address
	Amount int64
	Memo   string
}

func marshalTransfer(t Transfer) []byte {
	return wire.NewWriter().Addr(t.To).Int(t.Amount).Str(t.Memo).Bytes()
}

func unmarshalTransfer(b []byte) (Transfer, error) {
	r := wire.NewReader(b)
	t := Transfer{To: r.Addr(), Amount: r.Int(), Memo: r.Str()}
	if r.Err() != nil {
		return Transfer{}, r.Err()
	}
	if !r.Done() {
		return Transfer{}, errors.New("transfer: trailing bytes")
	}
	return t, nil
}

func Example_transfer() {
	in := Transfer{
		To:     address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5"),
		Amount: 12500,
		Memo:   "rent, split 3 ways", // commas need no escaping
	}
	out, err := unmarshalTransfer(marshalTransfer(in))
	if err != nil {
		panic(err)
	}
	fmt.Println(out.Amount, out.Memo, out == in)
	// Output: 12500 rent, split 3 ways true
}

// ---------- complex: nested structs and slices ----------

type Item struct {
	SKU   string
	Qty   uint64
	Price int64 // minor units
}

type Order struct {
	ID    uint64
	Buyer address
	Items []Item   // a slice of nested structs
	Tags  []string // a slice of scalars
	Paid  bool
	Note  string
}

func marshalOrder(o Order) []byte {
	w := wire.NewWriter().Uint(o.ID).Addr(o.Buyer)

	// A slice is a count followed by its elements. A nested struct is just its
	// fields, inline, in order.
	w.Uvarint(uint64(len(o.Items)))
	for _, it := range o.Items {
		w.Str(it.SKU).Uvarint(it.Qty).Int(it.Price)
	}

	w.Uvarint(uint64(len(o.Tags)))
	for _, tg := range o.Tags {
		w.Str(tg)
	}

	return w.Bool(o.Paid).Str(o.Note).Bytes()
}

func unmarshalOrder(b []byte) (Order, error) {
	r := wire.NewReader(b)
	var o Order
	o.ID = r.Uint()
	o.Buyer = r.Addr()

	items, err := readItems(r)
	if err != nil {
		return Order{}, err
	}
	o.Items = items

	tags, err := readTags(r)
	if err != nil {
		return Order{}, err
	}
	o.Tags = tags

	o.Paid = r.Bool()
	o.Note = r.Str()
	if r.Err() != nil {
		return Order{}, r.Err()
	}
	if !r.Done() {
		return Order{}, errors.New("order: trailing bytes")
	}
	return o, nil
}

// readItems shows the one rule that matters with untrusted input: never
// allocate on a length you have not bounded. Every element costs at least one
// byte, so a count larger than the bytes that remain is a lie -- reject it
// before make, and the loop below can never over-allocate or spin.
func readItems(r *wire.Reader) ([]Item, error) {
	n := r.Uvarint()
	if r.Err() != nil {
		return nil, r.Err()
	}
	if n > uint64(r.Remaining()) {
		return nil, errors.New("order: item count exceeds payload")
	}
	items := make([]Item, 0, n)
	for k := uint64(0); k < n; k++ {
		it := Item{SKU: r.Str(), Qty: r.Uvarint(), Price: r.Int()}
		if r.Err() != nil {
			return nil, r.Err()
		}
		items = append(items, it)
	}
	return items, nil
}

func readTags(r *wire.Reader) ([]string, error) {
	n := r.Uvarint()
	if r.Err() != nil {
		return nil, r.Err()
	}
	if n > uint64(r.Remaining()) {
		return nil, errors.New("order: tag count exceeds payload")
	}
	tags := make([]string, 0, n)
	for k := uint64(0); k < n; k++ {
		tags = append(tags, r.Str())
		if r.Err() != nil {
			return nil, r.Err()
		}
	}
	return tags, nil
}

func Example_order() {
	in := Order{
		ID:    9001,
		Buyer: address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5"),
		Items: []Item{
			{SKU: "WIDGET-001", Qty: 3, Price: 1999},
			{SKU: "GADGET-XL", Qty: 1, Price: 4999},
			{SKU: "BOLT-M4-PACK", Qty: 100, Price: 599},
		},
		Tags: []string{"priority", "fragile", "giftwrap"},
		Paid: true,
		Note: "leave at the back door; ring twice",
	}

	b := marshalOrder(in)
	out, err := unmarshalOrder(b)
	if err != nil {
		panic(err)
	}

	fmt.Println("bytes:", len(b))
	fmt.Println("items:", len(out.Items), "first:", out.Items[0].SKU, out.Items[0].Qty)
	fmt.Println("tags:", out.Tags)
	fmt.Println("paid:", out.Paid, "note:", out.Note)
	// Output:
	// bytes: 174
	// items: 3 first: WIDGET-001 3
	// tags: [priority fragile giftwrap]
	// paid: true note: leave at the back door; ring twice
}
