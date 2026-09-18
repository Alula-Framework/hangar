# Contributing

Thanks for your interest in hangar.

## Getting set up

The unit suite needs nothing:

```bash
swift build
swift test          # renderer, macro fixtures, predicates; integration skips
```

The integration suite needs a **dedicated, throwaway** PostgreSQL:

```bash
docker run -d --name hangar-test \
  -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=hangar_test \
  -p 55433:5432 postgres:16-alpine

export HANGAR_TEST_DATABASE_URL=\
"postgres://postgres:postgres@localhost:55433/hangar_test?sslmode=disable"

swift test          # the whole suite — unit and integration
```

`swift test`'s own closing line is not the total: it prints one "Test run with
N tests" per bundle, and the one that finishes last here reports **0**. That
number said `132` in this file for a long time while the suite was 325
swift-testing tests plus 88 XCTest. `CI/run-tests.sh` sums every bundle and
prints an accurate figure; prefer it when you want to know what ran.

> The integration suite drops and recreates its fixture tables. Point it at a
> database you care about and it will delete things.

## Before opening a pull request

```bash
swift build -Xswiftc -warnings-as-errors
swift test                              # with the database URL set
HANGAR_BUILD_DOCS=1 swift package generate-documentation \
    --target Hangar --warnings-as-errors
```

CI runs these against a Postgres service container, and **fails rather than
skips** if the database is unreachable — a green run that quietly skipped every
integration test proves almost nothing.

## The rule that governs most decisions

**A query that cannot be answered correctly must not be answered.**

The three worst bugs this library has had were all the same shape: a query
rendered successfully and returned the wrong number. A join silently dropped
the `GROUP BY` it was composed from. `count` ignored `DISTINCT`. A
connection-bound repo committed its caller's transaction. Nothing threw,
nothing logged; the answer was just wrong.

So: when a clause changes what a row *is*, it must survive every
transformation, or the transformation must refuse. When Hangar cannot know
something — whether a connection is already in a transaction, for instance —
the API asks the caller rather than guessing.

**Loud beats empty.** An unloaded association throws rather than returning
`[]`, because an empty array is indistinguishable from "there are none".

**Errors name the fix.** Every case in `HangarError` tells the reader what to
do. A new one should too.

## Testing

Renderer tests pin exact SQL text including placeholder numbering — that is
the right level for an AST→SQL layer, and a diff in that string is a real
change.

Macro fixtures in `HangarMacroTests` are normative: if an expansion changes,
that is an API change. Diagnostic message strings are pinned there too, so a
message and its fixture must change together.

`SilentWrongAnswerTests` exists for the class of bug described above. If you
fix one, it goes there.
