# HGR-QUERY-4006: A dynamic filter over a column whose type cannot be filtered

**Severity:** error (build)

## Meaning

`AnyColumn(\.someColumn)` names a column whose Swift type is not
`DynamicFilterConvertible`, so Hangar has no way to turn a request's filter
value — a string, number, boolean or null from a query string or JSON body —
into a value of that type.

## Why Hangar reports it

A dynamic filter takes its value from outside the program. Each filterable
type says how to read one safely: an `Int16` refuses 70000 rather than
wrapping it, a `UUID` refuses a malformed string rather than trapping. A type
without that rule cannot be offered to a caller.

## Fixes

1. Filter a column of a type that already conforms: `String`, `Int`, `Int16`, `Int32`, `Int64`, `Double`, `Bool`, `UUID`, `Date`.
2. For a `PostgresEnum`, opt in with one line: `extension Status: DynamicFilterConvertible {}` — labels map through `init(rawValue:)`.
3. For another type, conform it and implement `fromDynamicFilter(_:)`, returning `nil` for a value that does not fit.
4. Or leave the column out of `filterable`.

## Example

```swift
extension Priority: DynamicFilterConvertible {}   // a PostgresEnum

extension Incident: DynamicallyFilterable {
    static let filterable: [String: AnyColumn<Incident>] = [
        "priority": .init(\.priority),
        "severity": .init(\.severity),   // Int16
    ]
}
```

## Related

HGR-QUERY-4112, HGR-QUERY-4113.
