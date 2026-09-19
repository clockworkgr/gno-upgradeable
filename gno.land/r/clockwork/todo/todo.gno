// Package todo is an upgradeable realm with no application code in it at all.
//
// Everything below is forwarding. The realm has no interface to freeze, no
// state schema to regret, and no admin surface of its own — all of that is
// [app]'s, and none of it is permanent. What IS permanent is this file, which
// is why it says as little as possible.
//
// The application lives in gno.land/r/clockwork/todo/impl/*, where verbs and
// storage keys can be added at will. Compare gno.land/r/clockwork/counter,
// which declares a typed interface and typed entry points and pays for them
// by being unable to grow either.
package todo

import "gno.land/p/clockwork/app/v0"

// Admin may accept implementations, extend, and freeze. Replace it before
// deploying.
const Admin = address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5")

var a = app.New(app.Owner(Admin))

func init(cur realm)                              { a.Bind(0, cur) }
func Call(cur realm, verb, payload string) string { return a.Call(0, cur, verb, payload) }
func Register(cur realm, h app.Handler)           { a.Register(0, cur, h) }
func Manage(cur realm, verb, arg string) string   { return a.Admin(0, cur, verb, arg) }
func Store(_ int, rlm realm) *app.Store           { return a.Store(0, rlm) }
func Render(path string) string                   { return a.Render(path) }

// The API, queryable by anyone, without reading this source.
func Verbs() []string              { return a.Verbs() }
func Signature(verb string) string { return a.Signature(verb) }
func SchemaJSON() string           { return a.SchemaJSON() }

// The wiring, queryable the same way — what an operator needs from qeval.
func LivePath() string      { return a.LivePath() }
func PendingPaths() []string { return a.PendingPaths() }
func HistoryPaths() []string { return a.HistoryPaths() }
func Extensions() []string   { return a.Extensions() }
func Frozen() bool           { return a.Frozen() }
func Authority() string      { return a.Authority() }
