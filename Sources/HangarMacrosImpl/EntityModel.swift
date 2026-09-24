import SwiftSyntax
import SwiftSyntaxMacros

/// A stored property of an `@Entity` struct: either a column or an
/// association, in declaration order (the memberwise init and decoder walk
/// this order; everything else filters one side).
enum ParsedMember {
    case column(EntityProperty)
    case association(EntityAssociation)

    var identifier: String {
        switch self {
        case .column(let property): return property.identifier
        case .association(let association): return association.identifier
        }
    }
}

enum AssociationKind: String {
    case hasMany = "HasMany"
    case belongsTo = "BelongsTo"
    case hasOne = "HasOne"
}

/// One `@HasMany`/`@BelongsTo`/`@HasOne` property. Not a
/// column: excluded from the decoder, the schemas, and every bind switch
///; populated only by preload.
struct EntityAssociation {
    let identifier: String
    /// The full property type as written (`Loadable<[Comment]>`).
    let typeText: String
    let kind: AssociationKind
    /// The related entity's type name, unwrapped (`Comment`, `User`).
    let relatedTypeText: String
    /// The `foreignKey:` keypath expression, verbatim (`\Comment.postID`).
    /// Direct associations only; nil for a through association.
    let foreignKeyText: String?
    /// `@BelongsTo(references:)` if given; defaults to `\Related.id`.
    let referencesText: String?
    /// `@HasMany(through:from:to:)` — the join table's type name and its
    /// two keypath expressions, verbatim. Nil for direct associations.
    let throughText: (table: String, from: String, to: String)?
}

/// One stored property of an `@Entity` struct, as the macro understands it.
struct EntityProperty {
    let identifier: String
    /// The property's type exactly as written (`String?`, `[Int]`,...).
    let typeText: String
    /// For optionals, the wrapped type's text (`String` for `String?`);
    /// equal to `typeText` otherwise.
    let wrappedTypeText: String
    let isOptional: Bool
    let columnName: String
    let isPrimaryKey: Bool
    let isDeletedAt: Bool
    let isGenerated: Bool
    let isJSONB: Bool
    /// The initializer expression, if the property declares one — becomes
    /// the memberwise init's default value.
    let defaultValueText: String?
}

/// Parses the stored properties of an `@Entity` struct, emitting diagnostics
/// for shapes the macro can't support. Returns `nil` if anything was
/// diagnosed (expansion then produces nothing — the error is the output).
func parseEntityMembers(
    of structDecl: StructDeclSyntax,
    in context: some MacroExpansionContext
) -> [ParsedMember]? {
    var members: [ParsedMember] = []
    var failed = false

    for member in structDecl.memberBlock.members {
        guard let variable = member.decl.as(VariableDeclSyntax.self) else { continue }

        // Static/class members are not columns.
        if variable.modifiers.contains(where: { $0.name.tokenKind == .keyword(.static) || $0.name.tokenKind == .keyword(.class) }) {
            continue
        }

        // Computed properties are not columns; observers (willSet/didSet)
        // are still stored.
        if let accessorBlock = variable.bindings.first?.accessorBlock {
            switch accessorBlock.accessors {
            case .getter:
                continue
            case .accessors(let accessors):
                let observersOnly = accessors.allSatisfy {
                    $0.accessorSpecifier.tokenKind == .keyword(.willSet)
                        || $0.accessorSpecifier.tokenKind == .keyword(.didSet)
                }
                if !observersOnly { continue }
            }
        }

        guard variable.bindings.count == 1, let binding = variable.bindings.first else {
            context.diagnoseError(
                "entity.multibinding",
                "@Entity properties must be declared one per line — split 'let a, b: T' into separate declarations.",
                at: variable)
            failed = true
            continue
        }

        guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else {
            context.diagnoseError(
                "entity.pattern",
                "@Entity properties must be simple identifiers — tuple patterns can't map to columns.",
                at: binding)
            failed = true
            continue
        }

        guard let annotation = binding.typeAnnotation else {
            context.diagnoseError(
                "entity.untyped",
                "@Entity properties need an explicit type annotation — the column's Swift type is read from it.",
                at: variable)
            failed = true
            continue
        }

        // Associations take a different path from columns entirely.
        let associationAttribute = variable.attributes.compactMap { attribute -> (AssociationKind, AttributeSyntax)? in
            guard let attr = attribute.as(AttributeSyntax.self),
                let kind = AssociationKind(rawValue: attr.attributeName.trimmedDescription)
            else { return nil }
            return (kind, attr)
        }.first

        let isLoadable = loadableArgument(of: annotation.type) != nil

        if let (kind, attr) = associationAttribute {
            if let association = parseAssociation(
                kind: kind, attribute: attr, variable: variable,
                identifier: pattern.identifier.text, type: annotation.type, in: context) {
                members.append(.association(association))
            } else {
                failed = true
            }
            continue
        }

        if isLoadable {
            context.diagnoseError(
                "entity.loadablewithoutassociation",
                "A Loadable property needs an association attribute — mark it @HasMany, @BelongsTo, or @HasOne.",
                at: variable)
            failed = true
            continue
        }

        let isLet = variable.bindingSpecifier.tokenKind == .keyword(.let)
        if isLet, binding.initializer != nil {
            context.diagnoseError(
                "entity.letinitialized",
                "A 'let' with an initializer can't be decoded from a row (the value is already fixed). Make it 'var' or drop the initializer.",
                at: variable)
            failed = true
            continue
        }

        var isPrimaryKey = false
        var isDeletedAt = false
        var isGenerated = false
        var isJSONB = false
        var explicitName: String?

        for attribute in variable.attributes {
            guard let attr = attribute.as(AttributeSyntax.self) else { continue }
            switch attr.attributeName.trimmedDescription {
            case "ID":
                isPrimaryKey = true
                if let arguments = attr.arguments?.as(LabeledExprListSyntax.self),
                    let generated = arguments.first(where: { $0.label?.text == "generated" }) {
                    isGenerated = generated.expression.as(BooleanLiteralExprSyntax.self)?
                        .literal.tokenKind == .keyword(.true)
                }
            case "Column":
                guard let name = staticStringArgument(of: attr) else {
                    context.diagnoseError(
                        "entity.columnname",
                        "@Column needs a static string literal column name.",
                        at: attr)
                    failed = true
                    continue
                }
                explicitName = name
            case "JSONB":
                isJSONB = true
            case "Deleted":
                isDeletedAt = true
            default:
                continue
            }
        }

        let type = annotation.type
        let optionalWrapped: TypeSyntax? =
            type.as(OptionalTypeSyntax.self)?.wrappedType
            ?? type.as(IdentifierTypeSyntax.self).flatMap { identifier in
                identifier.name.text == "Optional"
                    ? identifier.genericArgumentClause?.arguments.first?.argument.as(TypeSyntax.self)
                    : nil
            }

        members.append(
            .column(
                EntityProperty(
                    identifier: pattern.identifier.text,
                    typeText: type.trimmedDescription,
                    wrappedTypeText: (optionalWrapped ?? type).trimmedDescription,
                    isOptional: optionalWrapped != nil,
                    columnName: explicitName ?? snakeCase(pattern.identifier.text),
                    isPrimaryKey: isPrimaryKey,
                    isDeletedAt: isDeletedAt,
                    isGenerated: isGenerated,
                    isJSONB: isJSONB,
                    defaultValueText: binding.initializer?.value.trimmedDescription)))
    }

    return failed ? nil : members
}

/// The generic argument of a `Loadable<...>` type annotation, or nil when
/// the type isn't Loadable.
private func loadableArgument(of type: TypeSyntax) -> TypeSyntax? {
    guard let identifier = type.as(IdentifierTypeSyntax.self),
        identifier.name.text == "Loadable",
        let argument = identifier.genericArgumentClause?.arguments.first?.argument.as(TypeSyntax.self)
    else { return nil }
    return argument
}

/// Validates and extracts one association property.
private func parseAssociation(
    kind: AssociationKind,
    attribute: AttributeSyntax,
    variable: VariableDeclSyntax,
    identifier: String,
    type: TypeSyntax,
    in context: some MacroExpansionContext
) -> EntityAssociation? {
    let hasColumnAttribute = variable.attributes.contains { attribute in
        guard let attr = attribute.as(AttributeSyntax.self) else { return false }
        return ["ID", "Column", "JSONB", "Deleted"].contains(attr.attributeName.trimmedDescription)
    }
    if hasColumnAttribute {
        context.diagnoseError(
            "entity.associationcolumn",
            "@\(kind.rawValue) can't combine with @ID/@Column/@JSONB — an association is not a column.",
            at: variable)
        return nil
    }
    guard variable.bindingSpecifier.tokenKind == .keyword(.var) else {
        context.diagnoseError(
            "entity.associationlet",
            "@\(kind.rawValue) properties must be 'var' — preload assigns into them.",
            at: variable)
        return nil
    }
    guard let argument = loadableArgument(of: type) else {
        context.diagnoseError(
            "entity.associationtype",
            "@\(kind.rawValue) properties must be Loadable — the runtime marker for \"populated only by preload\".",
            at: variable)
        return nil
    }

    let relatedTypeText: String?
    switch kind {
    case .hasMany:
        // Loadable<[Child]>
        relatedTypeText = argument.as(ArrayTypeSyntax.self)?.element.trimmedDescription
        if relatedTypeText == nil {
            context.diagnoseError(
                "entity.hasmanytype",
                "@HasMany properties must be Loadable<[Related]>.",
                at: variable)
        }
    case .hasOne:
        // Loadable<Child?> — absence is data.
        relatedTypeText = argument.as(OptionalTypeSyntax.self)?.wrappedType.trimmedDescription
        if relatedTypeText == nil {
            context.diagnoseError(
                "entity.hasonetype",
                "@HasOne properties must be Loadable<Related?> — \"no related row\" is data, expressed as .loaded(nil).",
                at: variable)
        }
    case .belongsTo:
        // Loadable<Child> (non-null FK) or Loadable<Child?> (nullable FK).
        // An array argument is a has-many shape wearing the wrong attribute;
        // without this check it escapes into the expansion as uncompilable
        // generated code with a baffling error at the generated line.
        let unwrapped = argument.as(OptionalTypeSyntax.self)?.wrappedType ?? argument
        if unwrapped.is(ArrayTypeSyntax.self) {
            context.diagnoseError(
                "entity.belongstotype",
                "@BelongsTo properties must be Loadable<Related> (non-null foreign key) or Loadable<Related?> (nullable) — for a collection, use @HasMany.",
                at: variable)
            relatedTypeText = nil
        } else {
            relatedTypeText = unwrapped.trimmedDescription
        }
    }
    guard let relatedTypeText else { return nil }

    let arguments = attribute.arguments?.as(LabeledExprListSyntax.self)
    func labeledArgument(_ label: String) -> String? {
        arguments?.first(where: { $0.label?.text == label })?.expression.trimmedDescription
    }

    if let throughExpression = labeledArgument("through") {
        guard kind == .hasMany else {
            context.diagnoseError(
                "entity.throughkind",
                "through: is @HasMany-only — @\(kind.rawValue) is a single-hop association.",
                at: attribute)
            return nil
        }
        guard let from = labeledArgument("from"), let to = labeledArgument("to") else {
            context.diagnoseError(
                "entity.throughkeys",
                "@HasMany(through:) needs from: and to: keypaths on the join table — from: references this entity's key, to: the related entity's.",
                at: attribute)
            return nil
        }
        // `PostTag.self` → `PostTag`.
        let throughType = throughExpression.hasSuffix(".self")
            ? String(throughExpression.dropLast(5))
            : throughExpression
        return EntityAssociation(
            identifier: identifier,
            typeText: type.trimmedDescription,
            kind: kind,
            relatedTypeText: relatedTypeText,
            foreignKeyText: nil,
            referencesText: nil,
            throughText: (table: throughType, from: from, to: to))
    }

    guard let foreignKey = labeledArgument("foreignKey") else {
        context.diagnoseError(
            "entity.associationkey",
            "@\(kind.rawValue) needs a foreignKey: keypath argument.",
            at: attribute)
        return nil
    }

    return EntityAssociation(
        identifier: identifier,
        typeText: type.trimmedDescription,
        kind: kind,
        relatedTypeText: relatedTypeText,
        foreignKeyText: foreignKey,
        referencesText: labeledArgument("references"),
        throughText: nil)
}

/// The first unlabeled argument of an attribute, if it is a plain string
/// literal (no interpolation).
func staticStringArgument(of attribute: AttributeSyntax) -> String? {
    guard
        let arguments = attribute.arguments?.as(LabeledExprListSyntax.self),
        let first = arguments.first, first.label == nil,
        let literal = first.expression.as(StringLiteralExprSyntax.self),
        literal.segments.count == 1,
        case .stringSegment(let segment) = literal.segments.first
    else { return nil }
    return segment.content.text
}

/// The static string passed as `label:`, `.some(nil)` when the argument is
/// absent, and nil when it is present but not a plain literal.
func labeledStringArgument(of attribute: AttributeSyntax, label: String) -> String?? {
    guard let arguments = attribute.arguments?.as(LabeledExprListSyntax.self),
        let argument = arguments.first(where: { $0.label?.text == label })
    else { return .some(nil) }
    if argument.expression.is(NilLiteralExprSyntax.self) { return .some(nil) }
    guard let literal = argument.expression.as(StringLiteralExprSyntax.self),
        literal.segments.count == 1,
        case .stringSegment(let segment) = literal.segments.first
    else { return nil }
    return .some(segment.content.text)
}

/// Default camelCase → snake_case column naming:
/// `viewCount` → `view_count`, `authorID` → `author_id`, `url` → `url`.
func snakeCase(_ name: String) -> String {
    var result = ""
    let characters = Array(name)
    for (index, character) in characters.enumerated() {
        if character.isUppercase {
            let previous = index > 0 ? characters[index - 1] : nil
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            // Underscore at a case boundary: after a lowercase/digit, or at
            // the last capital of an acronym run followed by lowercase.
            if let previous, previous.isLowercase || previous.isNumber {
                result.append("_")
            } else if let previous, previous.isUppercase, let next, next.isLowercase {
                result.append("_")
            }
            result.append(Character(character.lowercased()))
        } else {
            result.append(character)
        }
    }
    return result
}
