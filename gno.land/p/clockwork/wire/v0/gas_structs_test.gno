package wire_test

import (
	"strconv"
	"strings"
	"testing"
)

// Benchmarks encode and decode of a simple struct (Transfer) and a complex one
// (Order: nested structs + two slices), wire versus a hand-rolled delimited
// text codec — the thing you write when you do not have a binary codec.
//
//	gno test -v ./... -run TestGasS
//
// per-op = (GAS - TestGasSZeroLoop) / reps.
const reps = 200

var (
	benchTransfer = Transfer{
		To:     address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5"),
		Amount: 12500,
		Memo:   "rent, split 3 ways",
	}
	benchOrder = Order{
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

	wireTransfer = marshalTransfer(benchTransfer)
	wireOrder    = marshalOrder(benchOrder)
	textTransfer = encodeTransferText(benchTransfer)
	textOrder    = encodeOrderText(benchOrder)
)

// ---------- text baseline codec ----------

func encodeTransferText(t Transfer) string {
	return string(t.To) + "," + strconv.FormatInt(t.Amount, 10) + "," + t.Memo
}

func decodeTransferText(s string) Transfer {
	f := strings.SplitN(s, ",", 3) // memo may hold commas
	amt, _ := strconv.ParseInt(f[1], 10, 64)
	return Transfer{To: address(f[0]), Amount: amt, Memo: f[2]}
}

func encodeOrderText(o Order) string {
	items := []string{}
	for _, it := range o.Items {
		items = append(items, it.SKU+":"+strconv.FormatUint(it.Qty, 10)+":"+strconv.FormatInt(it.Price, 10))
	}
	paid := "0"
	if o.Paid {
		paid = "1"
	}
	return strconv.FormatUint(o.ID, 10) + "|" + string(o.Buyer) + "|" +
		strings.Join(items, ";") + "|" + strings.Join(o.Tags, ",") + "|" + paid + "|" + o.Note
}

func decodeOrderText(s string) Order {
	p := strings.SplitN(s, "|", 6)
	var o Order
	o.ID, _ = strconv.ParseUint(p[0], 10, 64)
	o.Buyer = address(p[1])
	if p[2] != "" {
		for _, its := range strings.Split(p[2], ";") {
			f := strings.Split(its, ":")
			qty, _ := strconv.ParseUint(f[1], 10, 64)
			price, _ := strconv.ParseInt(f[2], 10, 64)
			o.Items = append(o.Items, Item{SKU: f[0], Qty: qty, Price: price})
		}
	}
	if p[3] != "" {
		o.Tags = strings.Split(p[3], ",")
	}
	o.Paid = p[4] == "1"
	o.Note = p[5]
	return o
}

// ---------- benchmarks ----------

func TestGasSZeroLoop(t *testing.T) {
	s := 0
	for i := 0; i < reps; i++ {
		s += i
	}
	_ = s
}

// simple: encode
func TestGasSEncSimpleWire(t *testing.T) {
	n := 0
	for i := 0; i < reps; i++ {
		n += len(marshalTransfer(benchTransfer))
	}
	_ = n
}
func TestGasSEncSimpleText(t *testing.T) {
	n := 0
	for i := 0; i < reps; i++ {
		n += len(encodeTransferText(benchTransfer))
	}
	_ = n
}

// simple: decode
func TestGasSDecSimpleWire(t *testing.T) {
	n := 0
	for i := 0; i < reps; i++ {
		tr, _ := unmarshalTransfer(wireTransfer)
		n += len(tr.Memo)
	}
	_ = n
}
func TestGasSDecSimpleText(t *testing.T) {
	n := 0
	for i := 0; i < reps; i++ {
		tr := decodeTransferText(textTransfer)
		n += len(tr.Memo)
	}
	_ = n
}

// complex: encode
func TestGasSEncComplexWire(t *testing.T) {
	n := 0
	for i := 0; i < reps; i++ {
		n += len(marshalOrder(benchOrder))
	}
	_ = n
}
func TestGasSEncComplexText(t *testing.T) {
	n := 0
	for i := 0; i < reps; i++ {
		n += len(encodeOrderText(benchOrder))
	}
	_ = n
}

// complex: decode
func TestGasSDecComplexWire(t *testing.T) {
	n := 0
	for i := 0; i < reps; i++ {
		o, _ := unmarshalOrder(wireOrder)
		n += len(o.Items) + len(o.Tags)
	}
	_ = n
}
func TestGasSDecComplexText(t *testing.T) {
	n := 0
	for i := 0; i < reps; i++ {
		o := decodeOrderText(textOrder)
		n += len(o.Items) + len(o.Tags)
	}
	_ = n
}
