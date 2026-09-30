// occlude — reports containers whose `.accessibilityIdentifier` will overwrite
// their descendants'.
//
//   occlude <file.swift> [more.swift …]
//   occlude --selftest
//
// Exits 1 when it finds something, 0 when clean, 2 on a usage/IO error. It only analyses the files
// it is handed — choosing which files to scan (all views, staged files only, …) belongs to the
// caller, e.g. a pre-commit hook — so it stays testable in isolation.
import Foundation

let args = Array(CommandLine.arguments.dropFirst())

guard !args.isEmpty else {
    FileHandle.standardError.write(Data("""
        usage: occlude <file.swift> [...]
               occlude --selftest

        Reports a container .accessibilityIdentifier that overwrites its descendants'
        because the view declares no .accessibilityElement(children: .contain).

        """.utf8))
    exit(2)
}

if args.contains("--selftest") {
    exit(runSelfTest() ? 0 : 1)
}

let analyzer = IdentifierErasureAnalyzer()
var findings: [Finding] = []
var unreadable: [String] = []

for path in args {
    // An unreadable path is collected in `unreadable`; the run then writes the full list to
    // stderr and exits 2 (below), which is a louder signal than a log line would be.
    guard let source = try? String(contentsOfFile: path, encoding: .utf8) else {
        unreadable.append(path)
        continue
    }
    findings += analyzer.analyze(source: source, fileName: path)
}

// A file we could not read is NOT a clean file. Reporting "0 findings" while silently skipping
// inputs is the shape that makes a gate look green while checking nothing.
if !unreadable.isEmpty {
    let detail = "occlude: could not read \(unreadable.count) file(s):\n"
        + unreadable.map { "  \($0)\n" }.joined()
    FileHandle.standardError.write(Data(detail.utf8))
    exit(2)
}

for finding in findings.sorted(by: { ($0.file, $0.line) < ($1.file, $1.line) }) {
    print(finding.message)
}
print("occlude: scanned \(args.count) file(s), \(findings.count) finding(s)")
exit(findings.isEmpty ? 0 : 1)
