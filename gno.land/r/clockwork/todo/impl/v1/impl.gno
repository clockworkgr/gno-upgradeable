// Package impl is the second handler for gno.land/r/clockwork/todo.
//
// It declares two verbs the first one did not — "done" and "count" — and
// writes a key namespace the first one never used. Neither required a change
// to the todo realm, because that realm's API is a schema and its state is a
// map, and both are data.
//
// The change is additive, so the schema diff run at accept time finds nothing
// broken and the upgrade goes through. Dropping "add", or changing its
// parameter to an int, would be refused by the same check.
package impl

import (
	"strconv"
	"strings"

	"gno.land/p/clockwork/app/v0"
	"gno.land/r/clockwork/todo"
)

var schema = app.NewSchema(
	// Unchanged from v0: same name, same parameter, same result. A caller
	// written against v0 keeps working.
	app.Op("add", "Create a task.", app.KindInt,
		app.P("text", app.KindString, "what to do")),
	app.Op("list", "List every task, marking the done ones.", app.KindString),

	// New in v1.
	app.Op("done", "Mark a task complete.", app.KindString,
		app.P("id", app.KindInt, "the id returned by add")),
	app.Op("count", "How many tasks are still open.", app.KindInt),
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
			id := strings.TrimPrefix(k, "task/")
			mark := " "
			if st.Has("done/" + id) {
				mark = "x"
			}
			b.WriteString("[" + mark + "] " + id + " " + st.Get(k) + "\n")
		}
		return b.String()

	// done writes under done/, a namespace v0 never used. Tasks added by v0
	// are still here and still listed; they simply have no done/ entry.
	case "done":
		id := args.Int("id")
		if !st.Has(key(id)) {
			panic("todo: no such task: " + strconv.FormatInt(id, 10))
		}
		st.Set("done/"+strings.TrimPrefix(key(id), "task/"), "1")
		return "ok"

	case "count":
		open := 0
		for _, k := range st.KeysWithPrefix("task/") {
			if !st.Has("done/" + strings.TrimPrefix(k, "task/")) {
				open++
			}
		}
		return strconv.Itoa(open)
	}
	panic("todo/impl/v1: declared but unhandled verb: " + args.Verb())
}

func key(id int64) string {
	s := strconv.FormatInt(id, 10)
	return "task/" + strings.Repeat("0", 10-len(s)) + s
}

func Instance() app.Handler { return instance }

func init(cur realm) {
	todo.Register(cross(cur), instance)
}
