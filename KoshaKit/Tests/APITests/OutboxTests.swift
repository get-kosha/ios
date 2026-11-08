import Foundation
import Testing
import Model
import Store
import API

private func queued(_ id: String = UUID().uuidString) -> Queued {
    Queued(entry: NewTransaction(id: id, accountId: "a1", payee: "Tesco", amount: -1250,
                                categoryId: "groceries", day: "2026-11-04", time: "18:42"),
           currency: "eur", accountName: "Current account", categoryName: "Groceries", noEvent: true)
}

private func queueFile() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json") }

@Test func sentEntriesAreRemovedAndRetryBodiesStayIdentical() async throws {
    let requests = Requests()
    let fixture = HTTPFixture { request in
        await requests.record(request)
        return Reply(status: await requests.all.count == 1 ? 503 : 200)
    }
    fixture.signIn()
    let file = queueFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let outbox = Outbox(api: fixture.api(), file: file) { _ in }
    let item = queued()
    await outbox.add(item)
    #expect(await outbox.send().sent == 0)
    #expect(await outbox.items == [item])
    #expect(await outbox.send().sent == 1)
    #expect(await outbox.items.isEmpty)
    let bodies = await requests.all.map(\.httpBody)
    #expect(bodies.count == 2 && bodies[0] == bodies[1])
    let body = try KoshaJSON.decode(JSONValue.self, #require(bodies.first!))
    let tx = try #require(body["transactions"]?.array?.first)
    #expect(tx["id"]?.string == item.id)
    #expect(tx["eventId"] == .null)
    #expect(tx["time"]?.string == "18:42")
}

@Test(arguments: [429, 503, -1])
func retryableOutboxFailuresKeepEntries(status: Int) async throws {
    let fixture = HTTPFixture { _ in
        if status == -1 { throw URLError(.notConnectedToInternet) }
        return Reply(status: status)
    }
    fixture.signIn()
    let file = queueFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let outbox = Outbox(api: fixture.api(), file: file) { _ in }
    let item = queued()
    await outbox.add(item)
    let result = await outbox.send()
    #expect(result.sent == 0 && result.rejected.isEmpty)
    #expect(await outbox.items == [item])
    let reopened = Outbox(api: fixture.api(), file: file) { _ in }
    #expect(await reopened.items == [item])
}

@Test(arguments: [200, 404, 429, 503, 401])
func conflictChecksTheSavedTransaction(status: Int) async throws {
    let requests = Requests()
    let fixture = HTTPFixture { request in
        await requests.record(request)
        if request.httpMethod == "POST", request.url!.path == "/api/v1/transactions" {
            return Reply(status: 409, body: #"{"error":{"code":"conflict","message":"Already used"}}"#)
        }
        if request.url!.path.hasSuffix("/token") { return Reply(status: 400) }
        return Reply(status: status)
    }
    fixture.signIn()
    let file = queueFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let outbox = Outbox(api: fixture.api(), file: file) { _ in }
    let item = queued()
    await outbox.add(item)
    let result = await outbox.send()
    #expect(await requests.all.contains { $0.httpMethod == "GET" && $0.url!.path == "/api/app/transactions/\(item.id)" })
    if status == 200 {
        #expect(result.sent == 1 && result.rejected.isEmpty)
        #expect(await outbox.items.isEmpty)
    } else if status == 404 {
        #expect(result.rejected == ["Already used"])
        #expect(await outbox.items.isEmpty)
    } else {
        #expect(result.sent == 0 && result.rejected.isEmpty)
        #expect(await outbox.items == [item])
    }
}

@Test func refusedEntriesAreDroppedAndReportedInOrder() async throws {
    let fixture = HTTPFixture { _ in
        Reply(status: 403, body: #"{"error":{"code":"forbidden","message":"Demo is read-only"}}"#)
    }
    fixture.signIn()
    let file = queueFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let outbox = Outbox(api: fixture.api(), file: file) { _ in }
    await outbox.add(queued())
    await outbox.add(queued())
    let result = await outbox.send()
    #expect(result.sent == 0)
    #expect(result.rejected == ["Demo is read-only", "Demo is read-only"])
    #expect(await outbox.items.isEmpty)
}

@Test(.timeLimit(.minutes(1))) func concurrentSendsAndClearDoNotSendOldEntries() async throws {
    let arrived = Gate(), release = Gate(), requests = Requests()
    let fixture = HTTPFixture { request in
        await requests.record(request)
        await arrived.release()
        await release.wait()
        return Reply()
    }
    fixture.signIn()
    let file = queueFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let outbox = Outbox(api: fixture.api(), file: file) { _ in }
    await outbox.add(queued())
    await outbox.add(queued())
    let first = Task { await outbox.send() }
    await arrived.wait()
    let second = await outbox.send()
    #expect(second.sent == 0 && second.rejected.isEmpty)
    // Clearing invalidates an in-flight batch, even if a new session adds an entry before its reply comes back.
    await outbox.clear()
    let next = queued()
    await outbox.add(next)
    await release.release()
    _ = await first.value
    #expect(await requests.all.count == 1)
    #expect(await outbox.items == [next])
}
