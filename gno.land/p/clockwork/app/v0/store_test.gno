package app

import "testing"

// These exercise the kv data layer directly. The Store accessor that gates
// access to it is exercised end to end by the realm tests (todo_test) and its
// capability boundary by TestStoreRefusesAnUnrelatedRealm.

func TestKVBasics(t *testing.T) {
	s := newKV()

	if s.length() != 0 || s.has("a") || s.get("a") != "" {
		t.Error("a fresh kv should be empty")
	}

	s.set("b", "2")
	s.set("a", "1")
	s.set("c", "3")
	if s.length() != 3 {
		t.Errorf("expected 3 keys, got %d", s.length())
	}
	if s.get("b") != "2" {
		t.Errorf("expected 2, got %q", s.get("b"))
	}

	s.set("b", "22")
	if s.get("b") != "22" || s.length() != 3 {
		t.Error("overwriting a key should replace, not append")
	}

	if !s.del("b") || s.has("b") || s.length() != 2 {
		t.Error("del should remove the key")
	}
	if s.del("b") {
		t.Error("del should report false for an absent key")
	}
}

// Keys must come back in order regardless of insertion order: the prefix scan
// and any paging built on it depend on it.
func TestKVKeysAreSorted(t *testing.T) {
	s := newKV()
	for _, k := range []string{"m", "a", "z", "b", "y"} {
		s.set(k, k)
	}
	want := []string{"a", "b", "m", "y", "z"}
	got := s.allKeys()
	if len(got) != len(want) {
		t.Fatalf("expected %d keys, got %d", len(want), len(got))
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("at %d: expected %q, got %q", i, want[i], got[i])
		}
	}
}

func TestKVKeysIsACopy(t *testing.T) {
	s := newKV()
	s.set("a", "1")
	k := s.allKeys()
	k[0] = "zzz"
	if s.allKeys()[0] != "a" {
		t.Error("mutating the returned slice changed the kv")
	}
}

// Prefixes are how one store holds several collections.
func TestKVKeysWithPrefix(t *testing.T) {
	s := newKV()
	s.set("task/2", "b")
	s.set("task/1", "a")
	s.set("meta/next", "2")
	s.set("taskish", "not a task")

	got := s.keysWithPrefix("task/")
	if len(got) != 2 || got[0] != "task/1" || got[1] != "task/2" {
		t.Errorf("expected the two task keys in order, got %v", got)
	}
	if len(s.keysWithPrefix("nothing/")) != 0 {
		t.Error("an unmatched prefix should return nothing")
	}
}

func TestKVInts(t *testing.T) {
	s := newKV()

	if s.getInt("n") != 0 {
		t.Error("an absent int should read 0")
	}
	s.set("n", "not a number")
	if s.getInt("n") != 0 {
		t.Error("an unparsable int should read 0 rather than panic")
	}

	s.setInt("n", 41)
	if s.getInt("n") != 41 {
		t.Errorf("expected 41, got %d", s.getInt("n"))
	}
	if got := s.addInt("n", 1); got != 42 || s.getInt("n") != 42 {
		t.Errorf("addInt returned %d", got)
	}
	if got := s.addInt("fresh", 5); got != 5 {
		t.Errorf("addInt on an absent key should start from 0, got %d", got)
	}
}

// An absent key and a key set to "" read the same; has is the difference.
func TestKVEmptyValueIsNotAbsence(t *testing.T) {
	s := newKV()
	s.set("k", "")
	if !s.has("k") {
		t.Error("a key set to the empty string is still present")
	}
	if s.get("k") != s.get("absent") {
		t.Error("get cannot distinguish them, which is why has exists")
	}
}
