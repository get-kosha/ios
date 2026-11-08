import Foundation
import Testing
import Model
@testable import API
@testable import Store

@Test func rotatedTokensAreReadableFromASecondKeychainStore() async throws {
    let fixture = HTTPFixture { _ in
        Reply(body: #"{"access_token":"access-1","refresh_token":"refresh-1","expires_in":3600}"#)
    }
    fixture.signIn()
    let next = try await fixture.auth.refresh(failed: "access-0")
    #expect(TokenStore(service: fixture.keychainService).read() == next)
}

@Test func offlineRefreshKeepsTheSession() async throws {
    let fixture = HTTPFixture { _ in throw URLError(.notConnectedToInternet) }
    let original = fixture.signIn()
    do { _ = try await fixture.auth.refresh(failed: original.access); Issue.record("Refresh should fail offline") }
    catch KoshaError.offline { }
    #expect(fixture.store.read() == original)
}

@Test func discoveryReadsTheServersRegisteredEndpoints() async throws {
    let fixture = HTTPFixture { request in
        let origin = "https://" + request.url!.host!
        return Reply(body: """
            {"issuer":"\(origin)/api/auth","authorization_endpoint":"\(origin)/api/auth/oauth2/authorize",
             "token_endpoint":"\(origin)/api/auth/oauth2/token","revocation_endpoint":"\(origin)/api/auth/oauth2/revoke"}
            """)
    }
    let found = try await fixture.auth.discover(fixture.server)
    #expect(found.issuer == fixture.server + "/api/auth")
    #expect(found.tokenUrl == fixture.server + "/api/auth/oauth2/token")
}

@Test func old401CannotRefreshIntoANewSignIn() async throws {
    let arrived = Gate(), release = Gate(), requests = Requests()
    let fixture = HTTPFixture { request in
        await requests.record(request)
        await arrived.release()
        await release.wait()
        return Reply(status: 401)
    }
    fixture.signIn()
    let api = fixture.api()
    let old = Task { try await api.send("POST", "/api/v1/transactions", body: ["payee": "Example"]) }
    await arrived.wait()
    fixture.store.clear()
    let next = Tokens(server: fixture.server, clientId: clientId, access: "next-account", refresh: "next-refresh", expiresAt: 0)
    fixture.store.write(next)
    await release.release()
    await #expect(throws: KoshaError.self) { try await old.value }
    #expect(fixture.store.read() == next)
    #expect(await requests.all.count == 1)
}

@Test func invalidJSONNeverSendsAnEmptyMutation() async throws {
    let requests = Requests()
    let fixture = HTTPFixture { request in await requests.record(request); return Reply() }
    fixture.signIn()
    await #expect(throws: EncodingError.self) {
        try await fixture.api().send("PATCH", "/api/app/preferences", body: ["value": Double.infinity])
    }
    #expect(await requests.all.isEmpty)
}

@Test(arguments: ["https://other.example/token", "http://example.com/token", "not a URL"])
func discoveryRejectsForeignOrMalformedTokenEndpoints(endpoint: String) async throws {
    let fixture = HTTPFixture { request in
        let origin = "https://" + request.url!.host!
        return Reply(body: """
            {"issuer":"\(origin)/api/auth","authorization_endpoint":"\(origin)/authorize","token_endpoint":"\(endpoint)"}
            """)
    }
    await #expect(throws: KoshaError.self) { try await fixture.auth.discover(fixture.server) }
}

@MainActor
private func model(_ fixture: HTTPFixture, directory: URL) -> Kosha {
    let defaults = UserDefaults(suiteName: directory.lastPathComponent)!
    return Kosha(tokens: fixture.store, session: fixture.session,
                 cache: Cache(directory: directory.appendingPathComponent("cache")), local: LocalPrefs(defaults: defaults))
}

@Test @MainActor func signInLoadsMetaBeforeRevealingTheShell() async throws {
    let fixture = HTTPFixture { request in
        if request.url!.path == "/api/app/meta" {
            return Reply(body: #"{"tz":"Pacific/Kiritimati","demo":true,"wallets":[]}"#)
        }
        return Reply(body: #"{"user":{"name":"Demo","email":"demo@kosha.local"},"primaryCurrency":"eur","timeZone":"Pacific/Kiritimati"}"#)
    }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let kosha = model(fixture, directory: dir)
    #expect(!kosha.signedIn)
    fixture.signIn()
    await kosha.refresh()
    #expect(kosha.meta?.demo == true && kosha.settings?.user.email == "demo@kosha.local")
    #expect(!kosha.signedIn)
}

@Test @MainActor func oldLoadCannotRepopulateCacheAfterSignOut() async throws {
    let arrived = Gate(), release = Gate()
    let fixture = HTTPFixture { _ in Reply() }
    fixture.signIn()
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let kosha = model(fixture, directory: dir)
    kosha.cache.write("read", ["old"])
    let task = Task {
        await kosha.load("read", into: { (_: Loaded<[String]>) in }) { _ in
            await arrived.release()
            await release.wait()
            return ["old"]
        }
    }
    await arrived.wait()
    await kosha.outbox.add(Queued(entry: NewTransaction(accountId: "a1", payee: "Example", amount: -100),
                                  currency: "eur", accountName: "Example", categoryName: "Example"))
    await kosha.signOut()
    await release.release()
    await task.value
    #expect(kosha.cache.read("read", as: [String].self) == nil)
    #expect(await kosha.outbox.items.isEmpty)
    #expect(kosha.waiting.isEmpty && !kosha.signedIn)
}

@Test @MainActor func missingTokensClearTheSignedInAccountOnRefresh() async throws {
    let fixture = HTTPFixture { _ in Reply() }
    fixture.signIn()
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let kosha = model(fixture, directory: dir)
    kosha.cache.write("private", ["cached"])
    fixture.store.clear()
    await kosha.refresh()
    #expect(!kosha.signedIn && kosha.cache.read("private", as: [String].self) == nil)
    kosha.didSignIn()
    #expect(!kosha.signedIn)
}
