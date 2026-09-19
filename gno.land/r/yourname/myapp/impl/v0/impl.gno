// Package impl is where your application actually lives.
//
// Add verbs by adding a line to the schema and a case to the switch. Deploy
// the result at impl/v1, and the authority accepts it — the realm at
// gno.land/r/yourname/myapp never changes.
package impl

import (
	"gno.land/p/clockwork/app/v0"
	"gno.land/r/yourname/myapp"
)

// schema is your API, declared as data. It is what callers enumerate, what
// payloads are checked against before Handle runs, and what the next
// version's schema is diffed against so an upgrade cannot silently drop a
// verb someone depends on.
//
// Keep it in sync with the switch below — nothing checks that for you.
var schema = app.NewSchema(
	app.Op("ping", "Check the app is serving.", app.KindString),

	app.Op("set", "Store a value under a key.", app.KindNone,
		app.P("key", app.KindString, "where to put it"),
		app.P("value", app.KindString, "what to put there")),

	app.Op("get", "Read a value back.", app.KindString,
		app.P("key", app.KindString, "which key")),
)

type handler struct{}

var instance = &handler{}

func (h *handler) Schema() *app.Schema { return schema }

func (h *handler) Handle(_ int, rlm realm, args *app.Args) string {
	// Fetch the store once. It is your realm's state, not this realm's, so
	// it survives every future version of this file.
	st := myapp.Store(0, rlm)

	switch args.Verb() {
	case "ping":
		return "pong"

	case "set":
		// Both parameters are present and are strings: the app checked
		// before calling. Panic to reject anything the schema cannot express.
		st.Set(args.String("key"), args.String("value"))
		return "ok"

	case "get":
		return st.Get(args.String("key"))
	}

	// Unreachable — the app refuses a verb the schema does not declare — but
	// a schema and a switch are two lists that can drift apart.
	panic("myapp/impl/v0: declared but unhandled verb: " + args.Verb())
}

// Instance lets a governance realm register this explicitly instead of
// relying on init.
func Instance() app.Handler { return instance }

// init nominates this handler. Deploying is what registers it; it serves
// nothing until the authority runs Manage("accept", "<this path>").
func init(cur realm) {
	myapp.Register(cross(cur), instance)
}
