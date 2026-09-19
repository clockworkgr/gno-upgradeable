// Package impl is the first handler for gno.land/r/clockwork/todo.
//
// It declares two verbs. The next version declares four, and the todo realm
// does not change to allow that.
package impl

import (
	"strconv"
	"strings"

	"gno.land/p/clockwork/app/v0"
	"gno.land/r/clockwork/todo"
)

// schema is the API, as data. It is what `todo.Verbs()` enumerates, what
// payloads are checked against before Handle runs, and what the next version's
// schema is diffed against when someone tries to accept it.
var schema = app.NewSchema(
	app.Op("add", "Create a task.", app.KindInt,
		app.P("text", app.KindString, "what to do")),
	app.Op("list", "List every task, one per line.", app.KindString),
)

type handler struct{}

var instance = &handler{}

func (h *handler) Schema() *app.Schema { return schema }

func (h *handler) Handle(_ int, rlm realm, args *app.Args) string {
	st := todo.Store(0, rlm)
	switch args.Verb() {
	case "add":
		text := args.String("text")
		if strings.TrimSpace(text) == "" {
			panic("todo: a task needs a description")
		}
		id := st.AddInt("meta/next", 1)
		st.Set(key(id), text)
		return strconv.FormatInt(id, 10)

	case "list":
		var b strings.Builder
		for _, k := range st.KeysWithPrefix("task/") {
			b.WriteString(strings.TrimPrefix(k, "task/") + " " + st.Get(k) + "\n")
		}
		return b.String()
	}
	// Unreachable: the app refuses a verb the schema does not declare. Kept
	// because a schema and a switch are two lists that can drift apart.
	panic("todo/impl/v0: declared but unhandled verb: " + args.Verb())
}

// key zero-pads so that the store's sorted key order is numeric order.
func key(id int64) string {
	s := strconv.FormatInt(id, 10)
	return "task/" + strings.Repeat("0", 10-len(s)) + s
}

func Instance() app.Handler { return instance }

func init(cur realm) {
	todo.Register(cross(cur), instance)
}
