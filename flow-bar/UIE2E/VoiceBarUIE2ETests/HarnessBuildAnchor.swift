import XCTest

// Infrastructure provides a buildable UI-test bundle. The stacked coverage PR
// replaces this anchor with the real flow; no empty run can pass the exporter.
@MainActor
final class HarnessBuildAnchor: XCTestCase {}
