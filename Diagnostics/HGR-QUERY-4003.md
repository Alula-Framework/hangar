# HGR-QUERY-4003: A window frame bound that points the wrong way

**Severity:** error

## Meaning

A window frame starts at `UNBOUNDED FOLLOWING`, or ends at
`UNBOUNDED PRECEDING`.

## Why Hangar rejects it

Postgres rejects both: "frame start cannot be UNBOUNDED FOLLOWING" and
"frame end cannot be UNBOUNDED PRECEDING". A frame starts at or before where
it ends. Hangar makes the start and the end different types, `FrameStart` and
`FrameEnd`, so each side only offers the bounds that are legal there.

## Fixes

1. Start the frame at `.unboundedPreceding`, `.preceding(n)`, `.currentRow` or
   `.following(n)`.
2. Put `UNBOUNDED FOLLOWING` on the `to:` side, and `UNBOUNDED PRECEDING` on
   the `from:` side.

## Related

HGR-QUERY-4002.
