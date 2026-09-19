// Package myapp is a starting point. Copy this directory, change three
// things, and you have an upgradeable realm.
//
//  1. The namespace. Replace `yourname` everywhere — in both gnomod.toml
//     files, in the import below, and in the directory names. It has to be a
//     namespace you own, or r/sys/names refuses the deployment.
//  2. The name. `myapp` likewise, if you want something better.
//  3. Admin. Put your own address there.
//
// Then write your application in impl/v0. Nothing in this file needs to
// change again — not when you add a verb, not when you change how one
// behaves, not when you start storing something new. That is the point of it.
package myapp

import "gno.land/p/clockwork/app/v0"

// Admin may accept new implementations, register extensions, and freeze.
// Hand it to a governance realm once anyone else depends on this app:
//
//	Manage("govern", "gno.land/r/gov/dao")
const Admin = address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5")

var a = app.New(app.Owner(Admin))

// Everything below is a forward. A pure package cannot declare crossing
// functions, and MsgCall reaches a function by name at a realm path, so these
// have to live here — but none of them contains a decision.

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
