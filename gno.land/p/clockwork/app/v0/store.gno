package app

import "strconv"

// kv is the schema-free key/value data itself. It is unexported and never
// handed out: callers reach it only through a [Store], which gates every
// operation. Keeping the data and the accessor separate is what lets the
// accessor be a revocable capability while the data persists untouched.
//
// It exists because a struct's fields are as permanent as the realm that
// declares them: if your state is `type State struct { count int64 }` in a
// realm you can never redeploy, you can never add a second field. Keys are
// data, so a kv can grow forever. The trade is everything a type gives you:
// nothing is checked, values are strings, and a typo in a key is a silent
// empty read.
//
// # Where the writes land
//
// A kv is allocated by your realm, so Gno's storage-realm borrow persists
// every write in the realm that owns it -- not in the caller's. That is what
// lets an implementation realm mutate your state without holding any of it.
type kv struct {
	keys []string // sorted
	vals []string
}

func newKV() *kv { return &kv{} }

// find returns the insertion index for k and whether k is present.
func (s *kv) find(k string) (int, bool) {
	lo, hi := 0, len(s.keys)
	for lo < hi {
		mid := int(uint(lo+hi) >> 1)
		if s.keys[mid] < k {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo, lo < len(s.keys) && s.keys[lo] == k
}

func (s *kv) get(k string) string {
	if i, ok := s.find(k); ok {
		return s.vals[i]
	}
	return ""
}

func (s *kv) has(k string) bool {
	_, ok := s.find(k)
	return ok
}

func (s *kv) set(k, v string) {
	i, ok := s.find(k)
	if ok {
		s.vals[i] = v
		return
	}
	s.keys = append(s.keys, "")
	s.vals = append(s.vals, "")
	copy(s.keys[i+1:], s.keys[i:])
	copy(s.vals[i+1:], s.vals[i:])
	s.keys[i], s.vals[i] = k, v
}

func (s *kv) del(k string) bool {
	i, ok := s.find(k)
	if !ok {
		return false
	}
	s.keys = append(s.keys[:i], s.keys[i+1:]...)
	s.vals = append(s.vals[:i], s.vals[i+1:]...)
	return true
}

func (s *kv) length() int { return len(s.keys) }

func (s *kv) allKeys() []string {
	dup := make([]string, len(s.keys))
	copy(dup, s.keys)
	return dup
}

func (s *kv) keysWithPrefix(prefix string) []string {
	out := []string{}
	i, _ := s.find(prefix)
	for ; i < len(s.keys); i++ {
		k := s.keys[i]
		if len(k) < len(prefix) || k[:len(prefix)] != prefix {
			break
		}
		out = append(out, k)
	}
	return out
}

func (s *kv) getInt(k string) int64 {
	n, err := strconv.ParseInt(s.get(k), 10, 64)
	if err != nil {
		return 0
	}
	return n
}

func (s *kv) setInt(k string, v int64) { s.set(k, strconv.FormatInt(v, 10)) }

func (s *kv) addInt(k string, delta int64) int64 {
	n := s.getInt(k) + delta
	s.setInt(k, n)
	return n
}

// Store is the handler-facing accessor. It is NOT the data -- it is a
// permission to touch it, bound to the realm value it was issued for.
//
// This is what closes the capability leak. The old design handed out a raw
// pointer to the data, which a handler could stash in a package variable and
// keep using after it was rolled back or the realm was frozen. A Store holds
// the caller's realm value and re-checks it on every operation, so:
//
//   - It cannot be stashed. Assigning it to realm state persists the realm
//     value it carries, which the VM refuses ("cannot persist realm value"),
//     aborting the transaction. The capability cannot outlive the call.
//   - It cannot be replayed. Even held transiently, a Store whose frame has
//     returned fails IsCurrent() on its next use.
//
// So the grant lives and dies with the exact call frame that obtained it,
// which is the only window in which the caller is genuinely the live handler
// (or a registered extension). See [App.Store].
type Store struct {
	app *App
	rlm realm
}

// Get returns the value at k, or "" if absent. An absent key and a key set to
// "" read the same; use Has to tell them apart.
func (s *Store) Get(k string) string { return s.app.access(0, s.rlm).get(k) }

// Has reports whether k is present.
func (s *Store) Has(k string) bool { return s.app.access(0, s.rlm).has(k) }

// Set writes v at k.
func (s *Store) Set(k, v string) { s.app.access(0, s.rlm).set(k, v) }

// Delete removes k, reporting whether it was there.
func (s *Store) Delete(k string) bool { return s.app.access(0, s.rlm).del(k) }

// Len returns the number of keys.
func (s *Store) Len() int { return s.app.access(0, s.rlm).length() }

// Keys returns a copy of the keys, in order.
func (s *Store) Keys() []string { return s.app.access(0, s.rlm).allKeys() }

// KeysWithPrefix returns the keys under a prefix, in order. Prefixes are how
// a Store holds more than one collection: "task/1", "task/2", "meta/owner".
func (s *Store) KeysWithPrefix(prefix string) []string {
	return s.app.access(0, s.rlm).keysWithPrefix(prefix)
}

// GetInt reads k as an int64, returning 0 if it is absent or unparsable.
func (s *Store) GetInt(k string) int64 { return s.app.access(0, s.rlm).getInt(k) }

// SetInt writes an int64 at k.
func (s *Store) SetInt(k string, v int64) { s.app.access(0, s.rlm).setInt(k, v) }

// AddInt adds delta to k and returns the new value.
func (s *Store) AddInt(k string, delta int64) int64 { return s.app.access(0, s.rlm).addInt(k, delta) }
