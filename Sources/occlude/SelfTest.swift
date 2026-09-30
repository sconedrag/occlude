import Foundation

/// Proves the analyzer can still FAIL, and — just as importantly — that it stays SILENT on the
/// shapes that made the regex approach unusable.
///
/// A detector is only worth its blocking status if both directions are demonstrated. The positive
/// cases guard against a rule quietly going inert; the negative controls guard against it becoming
/// the noise generator it replaced. The two negatives below are not hypothetical: they are the two
/// files sampled from the regex pass's 28 hits, and both were false positives.
func runSelfTest() -> Bool {
    let analyzer = IdentifierErasureAnalyzer()
    var failures: [String] = []

    func check(_ name: String, _ source: String, expected: Int) {
        let got = analyzer.analyze(source: source, fileName: "<selftest>").count
        if got != expected {
            failures.append("  FAIL \(name): expected \(expected) finding(s), got \(got)")
        } else {
            print("  ok   \(name) (\(got) finding(s))")
        }
    }

    // ---- POSITIVE: the motivating shape, leaves in a SEPARATE member --------------------------
    // This is the case plain lexical containment misses entirely, so it is the load-bearing test.
    check("leaf in a separate computed property", """
    struct V: View {
        var body: some View {
            VStack { inputRow }
                .accessibilityIdentifier("composer.\\(id)")
        }
        private var inputRow: some View {
            TextField("x", text: $t)
                .accessibilityIdentifier("composer.textField.\\(id)")
        }
    }
    """, expected: 1)

    // Through a FUNC, and two hops deep — `body` -> `chip` -> `chipContent`.
    check("leaf two member hops away", """
    struct V: View {
        var body: some View {
            VStack { chip }.accessibilityIdentifier("a.\\(id)")
        }
        private var chip: some View { chipContent(target) }
        private func chipContent(_ t: T) -> some View {
            Button("x") {}.accessibilityIdentifier("a.cancel.\\(id)")
        }
    }
    """, expected: 1)

    // ---- POSITIVE: the fix is recognised ------------------------------------------------------
    check("declaring .contain clears it", """
    struct V: View {
        var body: some View {
            VStack { inputRow }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("composer.\\(id)")
        }
        private var inputRow: some View {
            TextField("x", text: $t).accessibilityIdentifier("composer.textField.\\(id)")
        }
    }
    """, expected: 0)

    // `.combine` and `.ignore` are NOT fixes — they destroy the leaf identifiers too.
    check(".combine is still a finding", """
    struct V: View {
        var body: some View {
            VStack { inputRow }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("composer.\\(id)")
        }
        private var inputRow: some View {
            TextField("x", text: $t).accessibilityIdentifier("composer.textField.\\(id)")
        }
    }
    """, expected: 1)

    // ---- NEGATIVE CONTROL 1: siblings (the FloatingTabBar false positive) ---------------------
    // `tab` and `tab.ai` share a stem prefix but neither contains the other. The regex flagged
    // this; anything that flags it here has not improved on the regex.
    check("sibling ids are NOT a container/leaf pair", """
    struct V: View {
        var body: some View {
            HStack {
                ForEach(tabs) { t in
                    Button("x") {}.accessibilityIdentifier("tab.\\(t.id)")
                }
                Button("ai") {}.accessibilityIdentifier("tab.ai")
            }
        }
    }
    """, expected: 0)

    // ---- NEGATIVE CONTROL 2: exclusive branches (the ConnectionsView false positive) ----------
    // The two ids are in `if` and `else`; they are never both on screen, and neither is applied
    // to an expression containing the other.
    check("if/else branches are NOT a container/leaf pair", """
    struct V: View {
        var body: some View {
            if ready {
                Label("a", systemImage: "x").accessibilityIdentifier("connections.row")
            } else {
                Label("b", systemImage: "x")
                    .accessibilityIdentifier("connections.row.preparing")
            }
        }
    }
    """, expected: 0)

    // ---- NEGATIVE CONTROL 3: two types in one file must not resolve each other's members ------
    check("members do not leak across types in a file", """
    struct A: View {
        var body: some View { VStack { Text("x") }.accessibilityIdentifier("a.\\(id)") }
    }
    struct B: View {
        var body: some View { inputRow }
        private var inputRow: some View {
            Text("y").accessibilityIdentifier("a.field.\\(id)")
        }
    }
    """, expected: 0)

    // ---- Waiver -------------------------------------------------------------------------------
    check("a11y-contain-ok waives", """
    struct V: View {
        var body: some View {
            VStack { inputRow }
                // a11y-contain-ok: leaves are addressed by label in this surface
                .accessibilityIdentifier("composer.\\(id)")
        }
        private var inputRow: some View {
            TextField("x", text: $t).accessibilityIdentifier("composer.textField.\\(id)")
        }
    }
    """, expected: 0)

    // A WRAPPED reason. This is the case that justifies reading trivia instead of a line window:
    // the marker is on the FIRST of two comment lines, so a fixed two-line lookback from the
    // identifier sees only the continuation and fails to waive. The repo's waiver allowlist marks
    // exactly this as the debt on its 46 `line-scoped` audits.
    check("a wrapped waiver reason still waives", """
    struct V: View {
        var body: some View {
            VStack { inputRow }
                // a11y-contain-ok: the leaves are addressed by label on this surface because
                // the identifiers are generated per row and are not stable across launches
                .accessibilityIdentifier("composer.\\(id)")
        }
        private var inputRow: some View {
            TextField("x", text: $t).accessibilityIdentifier("composer.textField.\\(id)")
        }
    }
    """, expected: 0)

    // And the inverse: a marker inside a STRING must not waive anything. A line-scanning lookback
    // cannot tell these apart; trivia can, because a string literal is not a comment.
    check("a marker inside a string literal does NOT waive", """
    struct V: View {
        var body: some View {
            VStack { inputRow }
                .help("write // a11y-contain-ok: to waive")
                .accessibilityIdentifier("composer.\\(id)")
        }
        private var inputRow: some View {
            TextField("x", text: $t).accessibilityIdentifier("composer.textField.\\(id)")
        }
    }
    """, expected: 1)

    // ---- Leaf controls own their label ---------------------------------------------------------
    // The real shape behind the two findings this tool originally left standing: a ProgressView
    // carrying `…button1.loading` inside a Button's `label:`, under the Button's own `…button1`.
    // `.contain` on a Button destroys its button trait and activation, so a finding here has no
    // safe remedy and must not be raised.
    check("a Button is not a container", """
    struct V: View {
        var body: some View {
            Button {
                save()
            } label: {
                if loading {
                    ProgressView().accessibilityIdentifier("creator.button1.loading")
                } else {
                    Text("Create")
                }
            }
            .accessibilityIdentifier("creator.button1")
        }
    }
    """, expected: 0)

    check("a NavigationLink is not a container", """
    struct V: View {
        var body: some View {
            NavigationLink { Detail() } label: {
                Text("Go").accessibilityIdentifier("row.link.title")
            }
            .accessibilityIdentifier("row.link")
        }
    }
    """, expected: 0)

    // NEGATIVE CONTROL for the exclusion itself. Without it, a broad "control-shaped things are
    // leaves" rule would swallow Menu — whose content IS a list of separately actionable items, so
    // a container id there erases real controls. The exclusion must be narrow enough to miss this.
    check("a Menu IS still a container", """
    struct V: View {
        var body: some View {
            Menu {
                Button("A") {}.accessibilityIdentifier("overflow.itemA")
                Button("B") {}.accessibilityIdentifier("overflow.itemB")
            } label: {
                Text("More")
            }
            .accessibilityIdentifier("overflow")
        }
    }
    """, expected: 1)

    // And the exclusion must key on the CHAIN ROOT, not on "a Button appears anywhere" — a VStack
    // containing buttons is a container and must still be flagged.
    check("a VStack containing Buttons is still a container", """
    struct V: View {
        var body: some View {
            VStack {
                Button("A") {}.accessibilityIdentifier("panel.buttonA")
            }
            .accessibilityIdentifier("panel")
        }
    }
    """, expected: 1)

    // ---- Recursion safety ---------------------------------------------------------------------
    // A self-referencing member must terminate rather than hang a pre-commit hook.
    check("self-referencing member terminates", """
    struct V: View {
        var body: some View { row.accessibilityIdentifier("a.\\(id)") }
        private var row: some View { row }
    }
    """, expected: 0)

    if failures.isEmpty {
        print("occlude --selftest: all cases behaved as specified")
        return true
    }
    print("occlude --selftest FAILED:")
    failures.forEach { print($0) }
    return false
}
