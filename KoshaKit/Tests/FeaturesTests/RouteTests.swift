import Testing
@testable import Features

@Test func addRequestsAreDistinct() {
    #expect(AddRequest() != AddRequest())
}
