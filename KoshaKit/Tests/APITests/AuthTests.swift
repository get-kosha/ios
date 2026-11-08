import CryptoKit
import Foundation
import Testing
import Model
@testable import API

private let tokenReply = Reply(body: #"{"access_token":"access-1","refresh_token":"refresh-1","expires_in":3600}"#)

@Test(arguments: [
    (" getkosha.app/ \n", "https://getkosha.app"),
    ("HTTPS://GETKOSHA.APP:443/path?q=x", "https://getkosha.app"),
    ("http://localhost:3456/", "http://localhost:3456"),
    ("http://127.0.0.1:80", "http://127.0.0.1"),
    ("", nil), ("http://example.com", nil), ("ftp://example.com", nil),
    ("https://example.com:99999", nil),
] as [(String, String?)])
func normalisesServer(input: String, expected: String?) {
    #expect(Auth.normalise(input) == expected)
}

@Test(arguments: [
    ("https://getkosha.app", "https://getkosha.app/app/oauth/callback?code=c", true),
    ("https://getkosha.app", "https://getkosha.app:443/app/oauth/callback?code=c", true),
    ("https://getkosha.app", "https://evil.example/app/oauth/callback?code=c", false),
    ("https://getkosha.app", "https://getkosha.app/other?code=c", false),
    ("https://getkosha.app", "http://getkosha.app/app/oauth/callback?code=c", false),
    ("https://getkosha.app", "https://getkosha.app:444/app/oauth/callback?code=c", false),
    ("http://localhost:3456", "http://localhost:3456/app/oauth/callback?code=c", true),
    ("http://localhost:3456", "http://localhost/app/oauth/callback?code=c", false),
    ("https://getkosha.app", "app.getkosha:/oauth/callback?code=c", true),
    ("https://getkosha.app", "app.getkosha://evil.example/oauth/callback?code=c", false),
    ("https://getkosha.app", "app.getkosha://oauth/wrong?code=c", false),
    ("https://getkosha.app", "app.getkosha:/oauth/callback?code=c&state=a&state=b", false),
])
func callbackIsBoundToItsDestination(server: String, redirect: String, accepted: Bool) {
    #expect((Auth.callback(server: server, redirect: URL(string: redirect)!)?["code"] == "c") == accepted)
}

private func pending(_ server: String) -> PendingSignIn {
    PendingSignIn(server: server, url: server + "/api/auth/oauth2/authorize", state: "state",
                  verifier: "verifier", tokenUrl: server + "/api/auth/oauth2/token", issuer: server + "/api/auth")
}

@Test func onlyAssociatedHTTPSOriginsUseTheHTTPSCallback() {
    #expect(pending("https://getkosha.app").httpsCallback)
    #expect(pending("https://getkosha.app:443").httpsCallback)
    #expect(!pending("http://getkosha.app").httpsCallback)
    #expect(!pending("https://getkosha.app:444").httpsCallback)
    #expect(!pending("https://self.example").httpsCallback)
    #expect(!pending("http://localhost:3456").httpsCallback)
}

@Test func authorizeAndExchangeUsePKCEAndTheHTTPSRedirect() async throws {
    let requests = Requests()
    let fixture = HTTPFixture { request in await requests.record(request); return tokenReply }
    let auth = fixture.auth
    let p = auth.start(pending(fixture.server), demo: true)
    let q = Auth.callback(server: fixture.server, redirect: URL(string: p.url.replacingOccurrences(
        of: "/api/auth/oauth2/authorize", with: callbackPath))!)!
    #expect(q["redirect_uri"] == fixture.server + callbackPath)
    #expect(q["resource"] == fixture.server + "/api/v1")
    #expect(q["client_id"] == "kosha-ios")
    #expect(q["code_challenge_method"] == "S256")
    #expect(q["code_challenge"] == Data(SHA256.hash(data: Data(p.verifier.utf8))).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: ""))
    #expect(p.verifier.count == 43)
    #expect(q["state"] == p.state && !p.state.isEmpty)
    #expect(q["login_hint"] == "demo" && q["prompt"] == "login")
    let tokens = try await auth.finish(p, redirect: URL(string:
        "app.getkosha:/oauth/callback?code=c&state=\(p.state)&iss=\(p.issuer)")!)
    let exchange = try #require(await requests.all.first)
    #expect(form(exchange)["redirect_uri"] == fixture.server + callbackPath)
    #expect(form(exchange)["code_verifier"] == p.verifier)
    #expect(form(exchange)["resource"] == fixture.server + "/api/v1")
    #expect(fixture.store.read() == tokens)
}

@Test(arguments: ["state=wrong&iss=ISS", "state=state&iss=https://evil.example", "state=state"])
func wrongOrMissingStateAndIssuerNeverExchange(query: String) async throws {
    let requests = Requests()
    let fixture = HTTPFixture { request in await requests.record(request); return tokenReply }
    let p = pending(fixture.server)
    let redirect = URL(string: "app.getkosha:/oauth/callback?code=c&" + query.replacingOccurrences(of: "ISS", with: p.issuer))!
    await #expect(throws: KoshaError.self) { try await fixture.auth.finish(p, redirect: redirect) }
    #expect(await requests.all.isEmpty)
    #expect(fixture.store.read() == nil)
}

@Test(arguments: [429, 408, 503])
func temporaryRefreshFailureKeepsTheSameToken(status: Int) async throws {
    let requests = Requests()
    let fixture = HTTPFixture { request in
        await requests.record(request)
        return Reply(status: status, body: "busy", headers: ["X-Retry-After": "7"])
    }
    let original = fixture.signIn()
    let auth = fixture.auth
    for _ in 0..<2 {
        do { _ = try await auth.refresh(failed: original.access); Issue.record("Refresh should wait") }
        catch KoshaError.retryLater(let seconds) { #expect(seconds == 7) }
        #expect(fixture.store.read() == original)
    }
    #expect(await requests.all.map { form($0)["refresh_token"] } == ["refresh-0", "refresh-0"])
}

@Test func refusedRefreshSignsOut() async throws {
    let fixture = HTTPFixture { request in
        Reply(status: request.url!.path.hasSuffix("/token") ? 400 : 401, body: #"{"error":"invalid_grant"}"#)
    }
    fixture.signIn()
    await #expect(throws: KoshaError.self) { try await fixture.api().bytes("/api/v1/accounts") }
    #expect(fixture.store.read() == nil)
}

@Test(arguments: [#"{"access_token":"","refresh_token":"r"}"#,
                  #"{"access_token":"a","refresh_token":"r","expires_in":9223372036854775807}"#,
                  #"{"access_token":"a","refresh_token":"r","expires_in":-1}"#])
func malformedTokenRepliesKeepTheSession(body: String) async throws {
    let fixture = HTTPFixture { _ in Reply(body: body) }
    let original = fixture.signIn()
    do { _ = try await fixture.auth.refresh(failed: original.access); Issue.record("Malformed reply should fail") }
    catch KoshaError.retryLater { }
    #expect(fixture.store.read() == original)
}

@Test func concurrent401RequestsShareRefreshAndReplayOnce() async throws {
    let requests = Requests()
    let originals = Gate()
    let refresh = Gate()
    let refreshing = Gate()
    let fixture = HTTPFixture { request in
        await requests.record(request)
        if request.url!.path == "/api/auth/oauth2/token" {
            await refreshing.release()
            await refresh.wait()
            return tokenReply
        }
        if request.value(forHTTPHeaderField: "Authorization") == "Bearer access-0" {
            if await requests.all.filter({ $0.url!.path == "/api/v1/accounts" }).count == 5 { await originals.release() }
            await originals.wait()
            return Reply(status: 401)
        }
        #expect(request.value(forHTTPHeaderField: "Accept-Language") == "de")
        return Reply(body: #"{"ok":true}"#)
    }
    fixture.signIn()
    let auth = fixture.auth
    let api = fixture.api(auth: auth)
    let tasks = (0..<5).map { _ in Task { try await api.bytes("/api/v1/accounts") } }
    await originals.wait()
    await refreshing.wait()
    await refresh.release()
    for task in tasks { _ = try await task.value }
    let all = await requests.all
    #expect(all.filter { $0.url!.path == "/api/auth/oauth2/token" }.count == 1)
    #expect(all.filter { $0.value(forHTTPHeaderField: "Authorization") == "Bearer access-1" }.count == 5)
    #expect(fixture.store.read()?.refresh == "refresh-1")
    let count = all.count
    #expect(try await auth.refresh(failed: "access-0")?.access == "access-1")
    #expect(await requests.all.count == count)
}

@Test func signingOutDuringRefreshNeverRestoresTokensOrRevokesTwice() async throws {
    let arrived = Gate(), release = Gate(), requests = Requests()
    let fixture = HTTPFixture { request in
        await requests.record(request)
        if request.url!.path.hasSuffix("/token") {
            await arrived.release()
            await release.wait()
            return tokenReply
        }
        return Reply(status: 503)
    }
    fixture.signIn()
    let auth = fixture.auth
    let refresh = Task { try await auth.refresh(failed: "access-0") }
    await arrived.wait()
    async let first: Void = auth.signOut()
    async let second: Void = auth.signOut()
    _ = await (first, second)
    await release.release()
    _ = try? await refresh.value
    #expect(fixture.store.read() == nil)
    #expect(await requests.all.filter { $0.url!.path.hasSuffix("/revoke") }.count == 1)
}
