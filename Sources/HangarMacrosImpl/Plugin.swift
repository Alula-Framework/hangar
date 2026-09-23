import SwiftCompilerPlugin
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

@main
struct HangarMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        EntityMacro.self,
        IDMacro.self,
        ColumnNameMacro.self,
        JSONBMacro.self,
        DeletedMacro.self,
        HasManyMacro.self,
        BelongsToMacro.self,
        HasOneMacro.self,
    ]
}

/// Shared diagnostic shape (same convention as Alula Core ): every
/// diagnostic names the fix, not just the problem — these fire at build time
/// and are the design's compile-time-first pitch in action.
struct HangarMacroDiagnostic: DiagnosticMessage {
    let message: String
    let id: String
    let severity: DiagnosticSeverity

    var diagnosticID: MessageID { MessageID(domain: "HangarMacros", id: id) }

    static func error(_ id: String, _ message: String) -> HangarMacroDiagnostic {
        HangarMacroDiagnostic(message: message, id: id, severity: .error)
    }

    /// For a convention the macro applies rather than a mistake it refuses:
    /// the expansion is still correct, but it made a choice the author
    /// should see rather than discover.
    static func warning(_ id: String, _ message: String) -> HangarMacroDiagnostic {
        HangarMacroDiagnostic(message: message, id: id, severity: .warning)
    }
}

extension MacroExpansionContext {
    func diagnoseError(_ id: String, _ message: String, at node: some SyntaxProtocol) {
        diagnose(Diagnostic(node: Syntax(node), message: HangarMacroDiagnostic.error(id, message)))
    }

    func diagnoseWarning(_ id: String, _ message: String, at node: some SyntaxProtocol) {
        diagnose(Diagnostic(node: Syntax(node), message: HangarMacroDiagnostic.warning(id, message)))
    }
}
