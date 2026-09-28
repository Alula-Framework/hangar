import PostgresNIO

/// The raw-SQL escape hatch, safe by construction: in
///
/// ```swift
/// Post.where { p in
///     p.published && SQLFragment("char_length(\(p.title)) > \(minLength)")
/// }
/// ```
///
/// the **literal** parts of the string become SQL, and every interpolated
/// value becomes a bound `$n` parameter — a Swift value cannot become SQL
/// text through interpolation, the same guarantee Ecto's `fragment/1`
/// makes. Interpolating a `Column` renders its (quoted) identifier, which
/// is how fragments reference real columns without strings.
///
/// For the rare case that genuinely needs computed SQL text there is
/// `\(raw:)`, which is exactly as dangerous as it sounds: the string goes
/// into the statement verbatim. Never pass it anything derived from user
/// input.
///
/// The boundary, precisely:
///
/// - **Parameterised:** every interpolated `ColumnCodable` value, optional
///   or not — sent as a bind, never as text.
/// - **Statement text:** the literal segments of the string as written in
///   source, interpolated `Column`s (as quoted identifiers from the entity's
///   own metadata), and `\(raw:)`.
/// - **Also statement text:** `SQLFragment(stringLiteral:)` called directly.
///   Swift passes only literals to it implicitly, but the initializer is
///   public and takes any `String`; called with a variable it is `\(raw:)`
///   by another name.
///
/// A value bound as a parameter cannot supply SQL syntax: it can fill a
/// value position, not name a column, a table, a sort direction, or an
/// operator. Those have to be chosen in code — typed columns, or a
/// `switch` over an allowlist that picks a literal.
public struct SQLFragment: Sendable, ExpressibleByStringInterpolation {
    enum Part: Sendable {
        case sql(String)
        case bind(SQLBind)
        /// A column reference, quoted — and qualified — at render time,
        /// not at interpolation time. When the fragment is built there is
        /// no way to know whether it will land in a single-table WHERE or
        /// inside a join, and only the renderer knows that; baking a bare
        /// quoted name here made every fragment column ambiguous in any
        /// multi-table scope.
        case column(table: String, name: String)
    }

    let parts: [Part]

    /// A literal-only fragment — pure SQL text, no binds.
    ///
    /// `value` becomes statement text verbatim. Written as a string literal
    /// that is source code; called directly with a runtime `String`, it is
    /// as unsafe as `\(raw:)`.
    public init(stringLiteral value: String) {
        self.parts = [.sql(value)]
    }

    /// Built by Swift's interpolation machinery — not called directly.
    public init(stringInterpolation: StringInterpolation) {
        self.parts = stringInterpolation.parts
    }

    /// The interpolation rules: literals are SQL, values are binds,
    /// columns are identifiers, `\(raw:)` is the announced escape hatch.
    public struct StringInterpolation: StringInterpolationProtocol, Sendable {
        var parts: [Part] = []

        /// Called by Swift's interpolation machinery — not user API.
        public init(literalCapacity: Int, interpolationCount: Int) {
            parts.reserveCapacity(interpolationCount * 2 + 1)
        }

        /// A literal segment of the interpolated string — statement text,
        /// verbatim. Called by Swift's interpolation machinery with the
        /// source code's own text; not user API.
        public mutating func appendLiteral(_ literal: String) {
            parts.append(.sql(literal))
        }

        /// A value — always a bound parameter.
        public mutating func appendInterpolation<V: ColumnCodable>(_ value: V) {
            parts.append(.bind(SQLBind(value)))
        }

        /// An optional value — a bound parameter or NULL.
        public mutating func appendInterpolation<V: ColumnCodable>(_ value: V?) {
            parts.append(.bind(SQLBind(value)))
        }

        /// A column — its quoted identifier, never a bind. In a
        /// multi-table scope (a join, a correlated subquery) it renders
        /// table-qualified, exactly as columns outside fragments do.
        public mutating func appendInterpolation<V>(_ column: Column<V>) {
            parts.append(.column(table: column.table, name: column.name))
        }

        /// Verbatim SQL text. The deliberate hole in the safety story, and
        /// it announces itself at every call site. Never user input.
        public mutating func appendInterpolation(raw: String) {
            parts.append(.sql(raw))
        }
    }
}

extension SQLFragment: PredicateConvertible {
    /// The fragment as a boolean predicate, composable with `&&`/`||`/`!`
    /// like any other.
    public var predicate: Predicate {
        Predicate(expression: .fragment(parts))
    }
}

extension SQLFragment {
    /// The fragment as a typed SELECT-list expression:
    ///
    /// ```swift
    /// Post.select { p in SQLFragment("char_length(\(p.body))").expression(as: Int.self) }
    /// ```
    public func expression<V>(as type: V.Type) -> SelectExpression<V> {
        SelectExpression(expression: .fragment(parts))
    }
}
