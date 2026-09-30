// swift-tools-version: 5.9
//
// occlude — finds a SwiftUI container whose `.accessibilityIdentifier`
// overwrites its descendants' identifiers because the view never declares
// `.accessibilityElement(children: .contain)`.
//
// WHY A SYNTAX-TREE TOOL AND NOT A REGEX.
// The defect is a STRUCTURAL property — "does the container's identifier apply to an ANCESTOR of
// the leaf's?" — and text cannot decide it. A regex pass over a real app's UI flagged 28 files;
// two of two spot-checked were false positives for two different reasons (sibling ids `tab.0` /
// `tab.ai` in a tab bar; mutually exclusive `if`/`else` branches). A gate with that precision is
// all noise, and a noisy gate teaches everyone to bypass it.
//
// WHY LEXICAL CONTAINMENT IS NOT ENOUGH EITHER.
// In the motivating case the container id sat on `body`, while the leaf ids sat in a separate
// function and a computed property of the same view. The leaves are NOT lexically inside `body`'s
// expression, so a plain tree-containment check finds no relationship in exactly the case this
// exists for. The tool therefore resolves intra-type view composition: it follows member
// references inside the container's subtree to their declarations on the same type, and collects
// identifier calls reachable that way.
//
// It never imports or builds your app; it only parses source text.

import PackageDescription

let package = Package(
    name: "occlude",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "occlude", targets: ["occlude"])
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "510.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "occlude",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            path: "Sources/occlude"
        ),
        // Tests are built into the binary: `occlude --selftest` runs positive and
        // negative controls (see Sources/occlude/SelfTest.swift), so the check can
        // be proved to FAIL on the defect and PASS on its look-alikes without an XCTest harness.
    ]
)
