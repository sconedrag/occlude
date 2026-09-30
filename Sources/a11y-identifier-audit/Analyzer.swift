import Foundation
import SwiftParser
import SwiftSyntax

/// One detected case of a container identifier that will overwrite its descendants'.
struct Finding {
    enum Kind {
        /// No `.accessibilityElement(children:)` anywhere in the container's modifier chain.
        case missingContain
        /// `.combine` merges the leaves into ONE element; `.ignore` hides them. Both destroy the
        /// leaf identifiers just as thoroughly as the bug, so neither is a fix for it.
        case wrongChildrenMode(String)
    }

    let file: String
    let line: Int
    let containerStem: String
    let leafStems: [String]
    let kind: Kind

    var message: String {
        let leaves = leafStems.sorted().joined(separator: ", ")
        switch kind {
        case .missingContain:
            return """
            \(file):\(line): container identifier "\(containerStem)" will overwrite its \
            descendants' identifiers (\(leaves)) — the view declares no \
            .accessibilityElement(children: .contain), so those leaves become unaddressable.
            """
        case .wrongChildrenMode(let mode):
            return """
            \(file):\(line): container identifier "\(containerStem)" declares \
            .accessibilityElement(children: .\(mode)), which does not preserve descendant \
            identifiers (\(leaves)). `.combine` merges them into one element and `.ignore` hides \
            them; only `.contain` keeps them addressable.
            """
        }
    }
}

/// Detects the identifier-erasure shape via the syntax tree.
///
/// The two things text could not do, and this does:
///   * it asks whether the leaf identifier is inside the expression the container identifier is
///     APPLIED TO — so sibling ids (`tab.0` / `tab.ai`) and mutually exclusive `if`/`else`
///     branches, both measured false positives of the regex pass, are silent here;
///   * it follows same-type member references, because in the motivating file the container sits
///     on `body` while the leaves sit in a separate property and func. Lexical containment alone
///     reports NOTHING on that file.
struct IdentifierErasureAnalyzer {

    func analyze(source: String, fileName: String) -> [Finding] {
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: fileName, tree: tree)
        var findings: [Finding] = []
        for scope in TypeScopeCollector.collect(in: tree) {
            findings += analyze(
                scope: scope,
                converter: converter,
                fileName: fileName
            )
        }
        return findings
    }

    private func analyze(
        scope: TypeScope,
        converter: SourceLocationConverter,
        fileName: String
    ) -> [Finding] {
        var findings: [Finding] = []

        for container in scope.identifierCalls {
            guard let stem = container.stem, !stem.isEmpty else { continue }
            // The expression the modifier is applied to: everything below it in the chain,
            // including intermediate modifiers and their closure arguments (`.overlay { … }`).
            guard let applied = container.call.calledExpression
                .as(MemberAccessExprSyntax.self)?.base else { continue }

            // A control whose label is its own content is NOT a container, and the fix this tool
            // prescribes would HARM it. `.accessibilityElement(children: .contain)` on a `Button`
            // turns a button into a container, losing its button trait and its activation — so a
            // finding here has no safe remedy, and raising one invites a damaging "fix".
            //
            // Found by investigating the two findings this tool left standing: both were a
            // `ProgressView` carrying `…button1.loading` inside a `Button`'s `label:`, under the
            // Button's own `…button1`. I had hypothesised those were a TOOLBAR-hoisting artifact;
            // reading them showed the real shape, and the toolbar framing was simply the wrong
            // question. Note this reasoning does NOT depend on whether the leaf is separately
            // addressable at runtime — it rests on the remedy being wrong for this shape, which is
            // decidable from the syntax alone.
            if isLeafControl(chainRootOf: container.call) { continue }

            let reachable = reachableIdentifierCalls(from: Syntax(applied), scope: scope)
            let leaves = reachable.compactMap(\.stem).filter { $0.hasPrefix(stem + ".") }
            guard !leaves.isEmpty else { continue }

            // The `.accessibilityIdentifier` TOKEN, not the call node. A modifier chain's
            // FunctionCallExpr starts at the base (`VStack`), often many lines earlier — so using
            // the node position reported a line the developer did not write the modifier on, and
            // made the waiver lookup search around the wrong line entirely.
            let anchor = container.call.calledExpression
                .as(MemberAccessExprSyntax.self)?.declName.baseName
                ?? container.call.calledExpression.firstToken(viewMode: .sourceAccurate)
            let position = anchor?.positionAfterSkippingLeadingTrivia
                ?? container.call.positionAfterSkippingLeadingTrivia
            let line = converter.location(for: position).line
            if isWaived(container.call) { continue }

            switch childrenMode(inChainOf: container.call) {
            case .some("contain"):
                continue  // correct — the leaves keep their own identifiers
            case .some(let other):
                findings.append(Finding(file: fileName, line: line, containerStem: stem,
                                        leafStems: Array(Set(leaves)),
                                        kind: .wrongChildrenMode(other)))
            case nil:
                findings.append(Finding(file: fileName, line: line, containerStem: stem,
                                        leafStems: Array(Set(leaves)), kind: .missingContain))
            }
        }
        return findings
    }

    // MARK: - Reach

    /// Identifier calls inside `root`, plus those inside same-type members `root` references.
    ///
    /// The member hop is the whole reason this is an AST tool: `body` composes `inputRow`, and the
    /// leaf identifiers live in `inputRow`. `visited` guards the recursion — a view that references
    /// itself would otherwise not terminate.
    private func reachableIdentifierCalls(
        from root: Syntax,
        scope: TypeScope,
        visited: Set<String> = []
    ) -> [IdentifierCall] {
        var result = IdentifierCallCollector.collect(in: root)

        var seen = visited
        for name in MemberReferenceCollector.collect(in: root, known: scope.memberNames) {
            guard !seen.contains(name), let body = scope.members[name] else { continue }
            seen.insert(name)
            result += reachableIdentifierCalls(from: body, scope: scope, visited: seen)
        }
        return result
    }

    // MARK: - Modifier chain

    /// The `children:` argument of `.accessibilityElement` anywhere in this modifier chain.
    ///
    /// Searched in BOTH directions — down the base spine and up through enclosing calls — rather
    /// than only before the identifier. Order does matter to SwiftUI, but a gate that blocks on
    /// ordering alone would flag correct-but-differently-arranged code, and a false positive on a
    /// blocking check is far more expensive than a missed one here.
    private func childrenMode(inChainOf call: FunctionCallExprSyntax) -> String? {
        var node: Syntax? = Syntax(call)
        while let current = node {
            if let fnCall = current.as(FunctionCallExprSyntax.self),
               let member = fnCall.calledExpression.as(MemberAccessExprSyntax.self),
               member.declName.baseName.text == "accessibilityElement",
               let arg = fnCall.arguments.first(where: { $0.label?.text == "children" }),
               let mode = arg.expression.as(MemberAccessExprSyntax.self)?.declName.baseName.text {
                return mode
            }
            node = current.parent
        }

        var base: ExprSyntax? = call.calledExpression.as(MemberAccessExprSyntax.self)?.base
        while let current = base {
            guard let fnCall = current.as(FunctionCallExprSyntax.self),
                  let member = fnCall.calledExpression.as(MemberAccessExprSyntax.self)
            else { break }
            if member.declName.baseName.text == "accessibilityElement",
               let arg = fnCall.arguments.first(where: { $0.label?.text == "children" }),
               let mode = arg.expression.as(MemberAccessExprSyntax.self)?.declName.baseName.text {
                return mode
            }
            base = member.base
        }
        return nil
    }

    /// Is the bottom of this modifier chain a control that OWNS its label as a single element?
    ///
    /// Deliberately a SHORT, conservative list rather than a guess at every SwiftUI type. Each of
    /// these renders its content as the control's own label, so `.contain` would convert a control
    /// into a container and break activation:
    ///   * `Button`         — label content is the button's label
    ///   * `NavigationLink` — same, plus a navigation action
    ///   * `Toggle` / `Link` — same shape
    ///
    /// `Menu` is NOT here, and that omission is deliberate: its content is a list of separate
    /// actionable items, so it is a genuine container and a container id there really does erase
    /// them. Guessing "anything control-shaped" would have swallowed that real case.
    private func isLeafControl(chainRootOf call: FunctionCallExprSyntax) -> Bool {
        let leafControls: Set<String> = ["Button", "NavigationLink", "Toggle", "Link"]

        var node: ExprSyntax? = call.calledExpression.as(MemberAccessExprSyntax.self)?.base
        while let current = node {
            if let fnCall = current.as(FunctionCallExprSyntax.self) {
                // The root of the chain: a call whose callee is a bare type name.
                if let name = fnCall.calledExpression.as(DeclReferenceExprSyntax.self)?
                    .baseName.text {
                    return leafControls.contains(name)
                }
                node = fnCall.calledExpression.as(MemberAccessExprSyntax.self)?.base
                continue
            }
            // A trailing-closure `Button { … } label: { … }` parses with the closures attached to
            // the call, so the bare-name case above catches it; anything else ends the walk.
            break
        }
        return false
    }

    /// `// a11y-contain-ok: <reason>` attached to the identifier modifier, read from the syntax
    /// tree's TRIVIA rather than from a window of source lines.
    ///
    /// Structural, not line-scoped, and the difference is not pedantry. A fixed N-line lookback
    /// cannot see a reason that wraps across lines — the repo's waiver-mechanism allowlist marks
    /// exactly that as debt on the 46 audits still doing it, and its `line-scoped` count is capped
    /// so it can only fall. Trivia is attached to the token by the parser, so a comment of any
    /// length or shape (`//` block, `/* */`) is found, and a coincidental match inside a string
    /// literal on a nearby line cannot produce a false waiver.
    private func isWaived(_ call: FunctionCallExprSyntax) -> Bool {
        guard let member = call.calledExpression.as(MemberAccessExprSyntax.self) else { return false }
        // The comment sits before `.accessibilityIdentifier`, so it lands on the period's leading
        // trivia; declName is checked too because formatting can attach it there instead.
        for trivia in [member.period.leadingTrivia, member.declName.baseName.leadingTrivia] {
            for piece in trivia {
                switch piece {
                case .lineComment(let text), .blockComment(let text),
                     .docLineComment(let text), .docBlockComment(let text):
                    if text.contains("a11y-contain-ok:") { return true }
                default:
                    continue
                }
            }
        }
        return false
    }
}
