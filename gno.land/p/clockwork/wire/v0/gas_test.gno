package wire

import (
	"strconv"
	"strings"
	"testing"
)

// These substantiate the package's reason to exist: wire decoding is flat in
// payload length, while a delimited-text baseline grows with it. Run with
//
//	gno test -v ./... -run TestGas
//
// and read the reported GAS lines: subtract TestGasBaseline and divide by N.
const N = 200

const bench40 = "g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5"

var (
	wStr8  = NewWriter().Str("buy milk").Bytes()
	wStr60 = NewWriter().Str("the quick brown fox jumps over the lazy dog and keeps going!!").Bytes()
	w3mix  = NewWriter().Addr(address(bench40)).Int(42).Str("rent").Bytes()

	cStr8  = "buy milk"
	cStr60 = "the quick brown fox jumps over the lazy dog and keeps going!!"
	c3mix  = bench40 + ",42,rent"
)

func TestGasBaseline(t *testing.T) {
	s := 0
	for i := 0; i < N; i++ {
		s += i
	}
	_ = s
}

// --- wire (this package): slice, no scan, fixed-width ints ---

func TestGasWireStr8(t *testing.T) {
	s := 0
	for i := 0; i < N; i++ {
		s += len(NewReader(wStr8).Str())
	}
	_ = s
}

func TestGasWireStr60(t *testing.T) {
	s := 0
	for i := 0; i < N; i++ {
		s += len(NewReader(wStr60).Str())
	}
	_ = s
}

func TestGasWire3mix(t *testing.T) {
	s := 0
	for i := 0; i < N; i++ {
		r := NewReader(w3mix)
		s += len(r.Addr()) + int(r.Int()) + len(r.Str())
	}
	_ = s
}

// --- CSV-style baseline: single-pass split + strconv (inlined) ---

func csvSplit(p string) []string {
	out := []string{}
	start := 0
	for k := 0; k < len(p); k++ {
		if p[k] == ',' {
			out = append(out, p[start:k])
			start = k + 1
		}
	}
	return append(out, p[start:])
}

func TestGasCSVStr8(t *testing.T) {
	s := 0
	for i := 0; i < N; i++ {
		s += len(csvSplit(cStr8)[0])
	}
	_ = s
}

func TestGasCSVStr60(t *testing.T) {
	s := 0
	for i := 0; i < N; i++ {
		s += len(csvSplit(cStr60)[0])
	}
	_ = s
}

func TestGasCSV3mix(t *testing.T) {
	s := 0
	for i := 0; i < N; i++ {
		f := csvSplit(c3mix)
		n, _ := strconv.ParseInt(f[1], 10, 64)
		s += len(f[0]) + int(n) + len(f[2])
	}
	_ = s
}

// keep strings imported for parity with the app's real decoder path
var _ = strings.TrimSpace
