# conformance

Shared fixtures. Each directory is one fixture set. The `CONFORMANCE` table in
`scripts/check.sh` names the executors that check each set.

## Golden files

These five sets are golden files: `authres`, `categorize`, `fx`, `norm-dates`
and `replay`. The TypeScript reference wrote them, and until it is removed its
generators still write the inputs. The Swift tests in
`ios/HasalaCore/Tests/HasalaCoreConformanceTests` own the expected output:

| Set | Swift test |
| --- | --- |
| `authres` | `AuthResultsConformanceTests/golden` |
| `categorize` | `CategorizeConformanceTests/golden` |
| `fx` | `FXConformanceTests/golden` |
| `norm-dates` | `NormDatesConformanceTests/golden` |
| `replay` | `ReplayConformanceTests/golden` |

Each test computes the expected output of every case with the Swift code and
writes the file as the generator does: two-space JSON, keys in their committed
order, a trailing newline, and every code point above U+007E as a `\uXXXX`
escape (except in `fx`, which is plain UTF-8). The test fails when one byte
differs.

### Update mode

When a behaviour change is intended, rewrite the expected output:

```sh
HASALA_UPDATE_GOLDEN=1 swift test --package-path ios/HasalaCore --filter HasalaCoreConformanceTests
swift test --package-path ios/HasalaCore --filter HasalaCoreConformanceTests
```

The first run writes the files. Other tests in that run still compare against
the old values, so run the suite again without the variable. Then review the
diff in `conformance/` line by line: it is the record of what changed.

Update mode rewrites only the `expect` of each case. It does not touch the
inputs, the notes or the manifests. To add a case, add its input (and, for
`replay` and `fx`, its `manifest.json` entry) by hand, then run update mode.

In `replay`, `expect.diagnostics` holds the TypeScript oracle's anomaly and
unreadable text, for reference. Update mode keeps it when the state hash does
not change, and drops it when the state changes.

Update mode never rewrites a case in `ReplayConformanceTests.disagreements`
(empty now). A case goes there only when Swift and the TypeScript oracle
disagree and the owner has not yet decided which side changes. The test
expects such a case to fail, and fails when it starts to pass.

### The gate

`scripts/check.sh` fails when a file under one of the five sets changes on a
branch with no change under `ios/HasalaCore/Tests`. In CI it compares with
`HEAD^1`; locally, with the merge base of `origin/main`.

## Swift-written sets

`swift/` is written by the Swift executor
(`HASALA_WRITE_SWIFT_GOLDENS=1 swift test --filter SwiftGoldenTests` or
`SwiftFoldGoldenTests`). `swift/fold-v4-edges.json` holds the v4 fold cases
that the TypeScript reference (schema 3) cannot express: held copies, the Undo
pairs, same-purchase pairing with archived and held rows, and money at the
Int64 limits.
