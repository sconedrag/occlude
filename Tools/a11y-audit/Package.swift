// swift-tools-version: 5.9
//
// a11y-audit — detects the D-UIT.2 defect: a container `.accessibilityIdentifier` that overwrites
// its descendants' own identifiers because the view never declares
// `.accessibilityElement(children: .contain)`.
//
// WHY A SWIFT PACKAGE AND NOT ANOTHER `scripts/audit_*.py`.
// The defect is a STRUCTURAL property — "does the container's identifier apply to an ANCESTOR of
// the leaf's?" — and text cannot decide it. A regex pass over `MyApp/UI` flagged 28 files;
// two of two spot-checked were false positives for two different reasons (sibling ids `tab.0` /
// `tab.ai` in FloatingTabBar; mutually exclusive `if`/`else` branches in ConnectionsView). A gate
// with that precision would be all noise, which teaches the bypass (CLAUDE.md Rule 42).
//
// WHY LEXICAL CONTAINMENT IS NOT ENOUGH EITHER, measured on the motivating case.
// In `InlineCommentComposer.swift` the container id sits at :76 on `body`, while the leaf ids sit
// at :109 (`replyChipContent`, a func), :140 and :161 (`inputRow`, a property). The leaves are NOT
// lexically inside `body`'s expression, so a plain tree-containment check finds zero relationship
// in the exact case this exists for. The tool therefore resolves intra-type view composition:
// follow the member references inside the container's subtree to their declarations on the same
// type, and collect identifier calls reachable that way.
//
// It does NOT import any MyApp target; it only parses source text, like Tools/devgraph.
//
// Rule statement: CLAUDE.md D-UIT.2. Wrapper + gate: scripts/audit_accessibility_identifier_erasure.py

import PackageDescription

let package = Package(
    name: "a11y-audit",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "a11y-identifier-audit", targets: ["a11y-identifier-audit"])
    ],
    dependencies: [
        // Same major as Tools/devgraph deliberately: SPM's shared cache then reuses that
        // checkout instead of fetching a second copy of a large dependency.
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "510.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "a11y-identifier-audit",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            path: "Sources/a11y-identifier-audit"
        ),
        // ⚠️ NO Swift testTarget, deliberately — and its absence is a FIX, not an omission.
        //
        // This manifest declared `.testTarget(path: "Tests/a11yIdentifierAuditTests")` from the
        // commit that introduced it (#2197). That directory has never existed: the same commit put
        // this tool's tests in `scripts/tests/test_a11y_identifier_gate.py`, in Python, alongside
        // the wrapper they actually exercise. SPM refuses to resolve a package whose target names a
        // missing custom path, so the declaration made the tool UNBUILDABLE from day one:
        //
        //     error: 'a11y-audit': invalid custom path 'Tests/a11yIdentifierAuditTests'
        //
        // Which made its pre-commit gate (`5ai`) inert — while still printing a BLOCKING verdict
        // naming a defect it had never looked for. The wrapper says "the check did NOT run" on one
        // line and asserts "a container identifier will erase its descendants' identifiers" four
        // lines later, so the only honest signal was buried above a confident false finding.
        // Rule 115(d): a tool that errored did not return a result.
        //
        // Tests: `scripts/tests/test_a11y_identifier_gate.py` (5 cases). Two of them were skipping
        // with the reason "no Swift toolchain" — which was also wrong; there is a toolchain, the
        // package simply would not build. They run now.
    ]
)
