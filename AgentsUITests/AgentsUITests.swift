import XCTest

/// Native UI acceptance is driven through the task's required CUA surface. This target keeps the
/// app's UI-test bundle buildable without introducing a second automation path.
final class AgentsUITests: XCTestCase {}
