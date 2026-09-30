# occlude

Finds SwiftUI views where a **container's `.accessibilityIdentifier` silently erases the
identifiers of the controls inside it** — the bug that makes an XCUITest report
"element not found" while the screenshot looks perfect.

```swift
var body: some View {
    VStack {
        TextField("Reply", text: $text)
            .accessibilityIdentifier("composer.field")   // ← unreachable from XCUITest
        Button("Send", action: send)
            .accessibilityIdentifier("composer.send")    // ← unreachable from XCUITest
    }
    .accessibilityIdentifier("composer")                 // ← overwrites both
}
```

Without `.accessibilityElement(children: .contain)` on the container, SwiftUI applies the
container's identifier over its descendants', so `app.textFields["composer.field"]` never
resolves. The leaves still render and VoiceOver still reads their labels (a different channel),
which is why this survives review: nothing looks wrong until a UI test or an automation driver
tries to address the control.

**The fix** is one modifier on the container:

```swift
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("composer")
```

`.combine` and `.ignore` are **not** fixes — `.combine` merges the leaves into one element and
`.ignore` hides them, destroying their identifiers just as thoroughly. The tool reports those too.

## Why a syntax-tree tool

A regex over a real app's views flagged 28 files; both spot-checked were false positives
(sibling identifiers such as `tab.0` / `tab.ai`, and mutually exclusive `if`/`else` branches).
This tool uses [SwiftSyntax](https://github.com/swiftlang/swift-syntax) to ask the structural
question — *is the leaf inside the expression the container identifier is applied to?* — and it
follows member references to other properties and functions **on the same type**, because the
common real-world shape puts the container identifier on `body` and the leaves in a helper
property. Plain lexical containment reports nothing on that shape.

## Install and run

Requires Swift 5.9+ on macOS 13+. It parses source text only; it never builds or imports your app.

```bash
git clone https://github.com/sconedrag/occlude
cd occlude
swift build -c release
.build/release/occlude path/to/View.swift [more.swift …]
```

Exit codes: `0` clean · `1` findings · `2` usage error or an unreadable file (an input it could
not read is never reported as clean).

```text
Sources/Composer.swift:11: container identifier "composer" will overwrite its descendants'
identifiers (composer.field, composer.send) — the view declares no
.accessibilityElement(children: .contain), so those leaves become unaddressable.
occlude: scanned 1 file(s), 1 finding(s)
```

### As a pre-commit check

The binary only analyses the files it is given, so scope is your choice — for example, staged
Swift files under your UI folder:

```bash
files=$(git diff --cached --name-only --diff-filter=ACM -- '*.swift')
# Skip when nothing is staged: run with no arguments, the tool exits 2 (usage).
[ -z "$files" ] || printf '%s\n' "$files" | tr '\n' '\0' | xargs -0 occlude
```

## Self-test

```bash
.build/release/occlude --selftest
```

Runs 15 built-in positive and negative controls, so the check is proved to fail on the defect as
well as to pass on clean code:

- **must report** — a leaf in a separate computed property, a leaf two member hops away,
  `.combine` used as a "fix", a `Menu` container, a `VStack` of `Button`s, and a waiver marker
  that only appears inside a string literal;
- **must stay silent** — `.contain` declared, sibling identifiers, `if`/`else` branches, members
  of a different type in the same file, a `Button` or `NavigationLink` (not containers), a
  self-referencing member (must terminate), and a real waiver comment (including one wrapped
  over several lines).

## Waiving a finding

When the leaves are deliberately addressed some other way (for example by label), put a comment
with a reason directly above the container's identifier:

```swift
    // a11y-contain-ok: rows are addressed by their label in UI tests
    .accessibilityIdentifier("settings.list")
```

The marker only counts in a comment — the same text inside a string literal does not waive.

## Limitations

- Composition is followed within one type. A leaf identifier set inside a *different* view type
  (a child `struct` you embed) is not traced.
- Identifiers are compared by their literal prefix: `"row.\(item.id)"` is treated as `row`.
  Everything from the first interpolation onward is a runtime value, so it is never assumed.
  An identifier passed as a non-literal expression (a constant, a function call) is not seen.

## License

Apache-2.0 — see [LICENSE](LICENSE).
