package app

import (
	"encoding/csv"
	"strings"
	"testing"
)

// Gas micro-benchmarks. Every test runs the same loop count, so subtracting
// TestGasBaseline and dividing by N gives the per-operation cost. Accumulators
// are local because a p/ package is immutable after init.
const N = 200

var (
	gvAdd   = Op("add", "", KindInt, P("text", KindString, ""))
	gvThree = Op("transfer", "", KindString,
		P("to", KindAddress, ""), P("amount", KindInt, ""), P("memo", KindString, ""))
	gvNone  = Op("ping", "", KindString)
	gSchema = NewSchema(gvAdd, gvThree, gvNone, Op("zeta", "", KindString))
	gAddr   = "g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5"
	gPay1   = "buy milk"
	gPay1Q  = `"buy milk, eggs"`
	gPay3   = gAddr + ",42,rent"
)

func TestGasBaseline(t *testing.T) {
	sink := 0
	for i := 0; i < N; i++ {
		sink += i
	}
	_ = sink
}

func TestGasLookupFirst(t *testing.T) {
	sink := 0
	for i := 0; i < N; i++ {
		v, _ := gSchema.Lookup("add")
		sink += len(v.Name)
	}
	_ = sink
}

func TestGasLookupLast(t *testing.T) {
	sink := 0
	for i := 0; i < N; i++ {
		v, _ := gSchema.Lookup("zeta")
		sink += len(v.Name)
	}
	_ = sink
}

func TestGasDecodeNoFields(t *testing.T) {
	sink := 0
	for i := 0; i < N; i++ {
		a, _ := decode(gvNone, "")
		sink += len(a.values)
	}
	_ = sink
}

func TestGasDecodeOneString(t *testing.T) {
	sink := 0
	for i := 0; i < N; i++ {
		a, _ := decode(gvAdd, gPay1)
		sink += len(a.values)
	}
	_ = sink
}

func TestGasDecodeLongString(t *testing.T) {
	long := "the quick brown fox jumps over the lazy dog and keeps going!!" // 60 chars, one field
	sink := 0
	for i := 0; i < N; i++ {
		a, _ := decode(gvAdd, long)
		sink += len(a.values)
	}
	_ = sink
}

func TestGasDecodeOneStringQuoted(t *testing.T) {
	sink := 0
	for i := 0; i < N; i++ {
		a, _ := decode(gvAdd, gPay1Q)
		sink += len(a.values)
	}
	_ = sink
}

func TestGasDecodeThreeMixed(t *testing.T) {
	sink := 0
	for i := 0; i < N; i++ {
		a, _ := decode(gvThree, gPay3)
		sink += len(a.values)
	}
	_ = sink
}

func TestGasEncodeOneString(t *testing.T) {
	sink := 0
	for i := 0; i < N; i++ {
		sink += len(Encode(gvAdd, gPay1))
	}
	_ = sink
}

// What a handler pays to read three fields it has been given.
func TestGasAccessorsThree(t *testing.T) {
	a, _ := decode(gvThree, gPay3)
	sink := 0
	for i := 0; i < N; i++ {
		sink += len(a.Address("to")) + int(a.Int("amount")) + len(a.String("memo"))
	}
	_ = sink
}

// Component costs, to show where the decode gas actually goes.
func TestGasComponentContainsAny(t *testing.T) {
	sink := 0
	for i := 0; i < N; i++ {
		if strings.ContainsAny(gPay3, "\"\r\n") {
			sink++
		}
	}
	_ = sink
}

func TestGasComponentStringsSplit(t *testing.T) {
	sink := 0
	for i := 0; i < N; i++ {
		sink += len(strings.Split(gPay3, ","))
	}
	_ = sink
}

func TestGasComponentSplitPlain(t *testing.T) {
	sink := 0
	for i := 0; i < N; i++ {
		r, _ := splitPlain(gPay3)
		sink += len(r)
	}
	_ = sink
}

func TestGasComponentCsvRead(t *testing.T) {
	sink := 0
	for i := 0; i < N; i++ {
		r, _ := csv.NewReader(strings.NewReader(gPay3)).Read()
		sink += len(r)
	}
	_ = sink
}

func TestGasComponentKindChecks(t *testing.T) {
	vals := []string{gAddr, "42", "rent"}
	sink := 0
	for i := 0; i < N; i++ {
		for j, p := range gvThree.Params {
			if p.Kind.parse(vals[j]) == nil {
				sink++
			}
		}
	}
	_ = sink
}
