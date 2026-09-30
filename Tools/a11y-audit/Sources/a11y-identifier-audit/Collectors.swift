import Foundation
import SwiftSyntax

/// One `.accessibilityIdentifier("…")` application.
struct IdentifierCall {
    let call: FunctionCallExprSyntax

    /// The literal prefix of the argument, before any interpolation, with trailing dots trimmed.
    ///
    /// `"a.field.\(viewModel.id)"` -> `a.field`; `"connections.bluetoothRow"` -> that, unchanged.
    /// Only the literal prefix is usable: everything from the first `\(…)` onward is a runtime
    /// value, so two ids agreeing there would be an assumption, not a fact.
    var stem: String? {
        guard let arg = call.arguments.first?.expression.as(StringLiteralExprSyntax.self) else {
            return nil
        }
        var literal = ""
        for segment in arg.segments {
            guard let text = segment.as(StringSegmentSyntax.self)?.content.text else { break }
            literal += text
        }
        while literal.hasSuffix(".") { literal.removeLast() }
        return literal.isEmpty ? nil : literal
    }
}

/// A type declaration and the members a SwiftUI view composes itself from.
struct TypeScope {
    /// Member name -> the body/getter to search when that member is referenced.
    let members: [String: Syntax]
    let identifierCalls: [IdentifierCall]
    var memberNames: Set<String> { Set(members.keys) }
}

enum TypeScopeCollector {
    /// One scope per type declaration. Scoping per-type rather than per-file matters: two views in
    /// the same file must not resolve each other's members, which would invent composition that
    /// does not exist.
    static func collect(in tree: SourceFileSyntax) -> [TypeScope] {
        let finder = TypeDeclFinder(viewMode: .sourceAccurate)
        finder.walk(tree)
        return finder.bodies.map { body in
            TypeScope(
                members: MemberBodyCollector.collect(in: body),
                identifierCalls: IdentifierCallCollector.collect(in: body)
            )
        }
    }

    private final class TypeDeclFinder: SyntaxVisitor {
        var bodies: [Syntax] = []
        override func visit(_ n: StructDeclSyntax) -> SyntaxVisitorContinueKind {
            bodies.append(Syntax(n.memberBlock)); return .skipChildren
        }
        override func visit(_ n: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
            bodies.append(Syntax(n.memberBlock)); return .skipChildren
        }
        override func visit(_ n: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
            bodies.append(Syntax(n.memberBlock)); return .skipChildren
        }
    }
}

/// Computed properties and functions — the units a SwiftUI view composes from.
///
/// Stored properties are deliberately excluded: `let x = Foo()` is not a view-builder the
/// container renders into in the sense this analysis cares about.
enum MemberBodyCollector {
    static func collect(in root: Syntax) -> [String: Syntax] {
        let visitor = Visitor(viewMode: .sourceAccurate)
        visitor.walk(root)
        return visitor.members
    }

    private final class Visitor: SyntaxVisitor {
        var members: [String: Syntax] = [:]

        override func visit(_ n: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
            for binding in n.bindings {
                guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?
                    .identifier.text, let accessor = binding.accessorBlock else { continue }
                members[name] = Syntax(accessor)
            }
            return .visitChildren
        }

        override func visit(_ n: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
            if let body = n.body { members[n.name.text] = Syntax(body) }
            return .visitChildren
        }
    }
}

enum IdentifierCallCollector {
    static func collect(in root: Syntax) -> [IdentifierCall] {
        let visitor = Visitor(viewMode: .sourceAccurate)
        visitor.walk(root)
        return visitor.calls
    }

    private final class Visitor: SyntaxVisitor {
        var calls: [IdentifierCall] = []
        override func visit(_ n: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
            if let member = n.calledExpression.as(MemberAccessExprSyntax.self),
               member.declName.baseName.text == "accessibilityIdentifier" {
                calls.append(IdentifierCall(call: n))
            }
            return .visitChildren
        }
    }
}

/// References to same-type members: bare `inputRow` and explicit `self.inputRow`.
///
/// Filtered against the type's KNOWN member names, so an unrelated `.text` or a local variable
/// cannot masquerade as a view-composition hop.
enum MemberReferenceCollector {
    static func collect(in root: Syntax, known: Set<String>) -> [String] {
        let visitor = Visitor(viewMode: .sourceAccurate, known: known)
        visitor.walk(root)
        return Array(visitor.found)
    }

    private final class Visitor: SyntaxVisitor {
        let known: Set<String>
        var found: Set<String> = []

        init(viewMode: SyntaxTreeViewMode, known: Set<String>) {
            self.known = known
            super.init(viewMode: viewMode)
        }

        override func visit(_ n: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
            let name = n.baseName.text
            if known.contains(name) { found.insert(name) }
            return .visitChildren
        }

        override func visit(_ n: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
            if n.base?.as(DeclReferenceExprSyntax.self)?.baseName.tokenKind == .keyword(.self) {
                let name = n.declName.baseName.text
                if known.contains(name) { found.insert(name) }
            }
            return .visitChildren
        }
    }
}
