import SwiftSyntax
import SwiftSyntaxMacros

/// `@ID`, `@Column`, `@JSONB` are pure markers: all generated code lives in
/// `@Entity`'s expansion, which reads these attributes off the properties.
/// Their own expansions are empty; their job is validating the attachment
/// site so misuse fails on the property, not somewhere inside the enclosing
/// type's expansion — the same pattern as Alula's `@Inject`.

public struct IDMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        validateColumnAttribute(node, declaration, name: "@ID", in: context)
        return []
    }
}

public struct ColumnNameMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        validateColumnAttribute(node, declaration, name: "@Column", in: context)
        return []
    }
}

public struct DeletedMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        validateColumnAttribute(node, declaration, name: "@Deleted", in: context)
        return []
    }
}

public struct JSONBMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        validateColumnAttribute(node, declaration, name: "@JSONB", in: context)
        return []
    }
}

/// `@HasMany`/`@BelongsTo`/`@HasOne`: markers like the
/// column attributes — @Entity's expansion reads them and generates the
/// association registry; their own expansions are empty. Deep validation
/// (Loadable shape, var-ness, attribute exclusivity) happens in @Entity's
/// parse, where the full property is in view.

public struct HasManyMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        validateColumnAttribute(node, declaration, name: "@HasMany", in: context)
        return []
    }
}

public struct BelongsToMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        validateColumnAttribute(node, declaration, name: "@BelongsTo", in: context)
        return []
    }
}

public struct HasOneMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        validateColumnAttribute(node, declaration, name: "@HasOne", in: context)
        return []
    }
}

/// Shared validation: must be a stored property with a type annotation.
private func validateColumnAttribute(
    _ node: AttributeSyntax,
    _ declaration: some DeclSyntaxProtocol,
    name: String,
    in context: some MacroExpansionContext
) {
    guard let variable = declaration.as(VariableDeclSyntax.self) else {
        context.diagnoseError(
            "column.notproperty",
            "\(name) can only be attached to a stored property of an @Entity struct.",
            at: node)
        return
    }
    if let binding = variable.bindings.first, binding.typeAnnotation == nil {
        context.diagnoseError(
            "column.untyped",
            "\(name) properties need an explicit type annotation — the column's Swift type is read from it.",
            at: variable)
    }
}
