import CryptoKit
import Foundation
import Testing

@testable import TrayNook

@Suite("Verified update staging", .serialized)
@MainActor
struct UpdateControllerTests {
  @Test("Stable versions need a newer numeric build, no marketing downgrade, and a compatible OS")
  func versionOrdering() throws {
    let fixture = try UpdateFixture()
    defer { fixture.clean() }
    let update = try fixture.release(version: "1.10.0", build: "11", minimum: "13.1")
    #expect(update.isNewer(thanVersion: "1.9.9", build: "10", systemVersion: "13.1.0"))
    #expect(!update.isNewer(thanVersion: "1.9.9", build: "12", systemVersion: "14.0"))
    #expect(!update.isNewer(thanVersion: "2.0.0", build: "10", systemVersion: "14.0"))
    #expect(!update.isNewer(thanVersion: "1.9.9", build: "10", systemVersion: "13.0.9"))
    #expect(update.isNewer(thanVersion: "1.10.0", build: "10", systemVersion: "14.0"))
    #expect(throws: (any Error).self) { try fixture.release(version: "1.10.0-beta.1").validate() }
    #expect(throws: (any Error).self) { try fixture.release(build: "0").validate() }
  }

  @Test("The archive is pinned to the exact HTTPS release path")
  func untrustedURLs() throws {
    let fixture = try UpdateFixture()
    defer { fixture.clean() }
    for address in [
      "http://github.com/TrayNook/traynook/releases/download/v1.1.0/TrayNook-1.1.0.zip",
      "https://evil.example/TrayNook/traynook/releases/download/v1.1.0/TrayNook-1.1.0.zip",
      "https://github.com.evil.example/TrayNook/traynook/releases/download/v1.1.0/TrayNook-1.1.0.zip",
      "https://user:password@github.com/TrayNook/traynook/releases/download/v1.1.0/TrayNook-1.1.0.zip",
      "https://github.com/TrayNook/traynook/releases/download/v1.1.0/TrayNook-1.1.0.zip?download=1",
      "https://github.com/TrayNook/traynook/releases/download/v1.1.0/TrayNook-1.1.0.zip#fragment",
      "https://github.com/TrayNook/traynook/releases/download/v1.1.0/other.zip",
      "https://github.com/TrayNook/traynook/releases/download/v1.1.0/%54rayNook-1.1.0.zip",
    ] {
      #expect(throws: (any Error).self) { try fixture.release(address: address).validate() }
    }
    try fixture.release().validate()
  }

  @Test("Appcast parsing preserves plain text and rejects XML entities, oversized feeds, and invalid stable items")
  func feedBoundaries() throws {
    let fixture = try UpdateFixture()
    defer { fixture.clean() }
    let release = try fixture.release()
    let feed = fixture.feed(release)
    #expect(try UpdateController.parseFeed(feed) == [release])
    #expect(throws: (any Error).self) {
      try UpdateController.parseFeed(Data("<!DOCTYPE rss [<!ENTITY file SYSTEM 'file:///etc/passwd'>]>".utf8) + feed)
    }
    #expect(throws: (any Error).self) {
      try UpdateController.parseFeed(Data(repeating: 32, count: UpdateController.maximumFeedSize + 1))
    }
    let malicious = String(decoding: feed, as: UTF8.self).replacingOccurrences(of: "https://github.com/", with: "https://evil.example/")
    #expect(throws: (any Error).self) { try UpdateController.parseFeed(Data(malicious.utf8)) }
  }

  @Test("Signed staging survives launch; tampering never reaches the explicit installer")
  func cacheAndInstall() throws {
    let fixture = try UpdateFixture()
    defer { fixture.clean() }
    let controller = fixture.controller()
    let release = try fixture.release()
    var installations = 0
    controller.installRelease = { _, _ in installations += 1 }
    try controller.stageArchive(at: fixture.archive, release: release)
    #expect(installations == 0)
    let staged = try #require(controller.downloadedArchive)
    let restored = fixture.controller()
    #expect(restored.release == release)
    #expect(restored.downloadedArchive == staged)
    restored.installRelease = { actualRelease, archive in
      #expect(actualRelease == release)
      #expect(archive == staged)
      installations += 1
    }
    #expect(installations == 0)
    restored.install()
    #expect(installations == 1)

    try Data(repeating: 0, count: fixture.payload.count).write(to: staged)
    restored.install()
    #expect(installations == 1)
    #expect(restored.downloadedArchive == nil)
    #expect(fixture.controller().downloadedArchive == nil)
  }

  @Test("Failed signature verification preserves the previous verified staged archive")
  func invalidSignature() throws {
    let fixture = try UpdateFixture()
    defer { fixture.clean() }
    let controller = fixture.controller()
    let first = try fixture.release()
    try controller.stageArchive(at: fixture.archive, release: first)
    let staged = try #require(controller.downloadedArchive)
    let impostor = Curve25519.Signing.PrivateKey()
    let invalid = try fixture.release(version: "1.2.0", build: "3", signingKey: impostor)
    #expect(throws: (any Error).self) { try controller.stageArchive(at: fixture.archive, release: invalid) }
    #expect(controller.downloadedArchive == staged)
    #expect(controller.release == first)
    #expect(FileManager.default.fileExists(atPath: staged.path))
  }

  @Test("Launching an installed or newer build removes its obsolete cached update", arguments: ["2", "3"])
  func removesInstalledArchive(currentBuild: String) throws {
    let fixture = try UpdateFixture()
    defer { fixture.clean() }
    let controller = fixture.controller()
    try controller.stageArchive(at: fixture.archive, release: fixture.release())
    let staged = try #require(controller.downloadedArchive)
    let metadata = staged.deletingLastPathComponent().appendingPathComponent("release.json")
    let unrelated = staged.deletingLastPathComponent().appendingPathComponent("keep.zip")
    try fixture.payload.write(to: unrelated)

    let relaunched = fixture.controller(currentVersion: "1.1.0", currentBuild: currentBuild)
    #expect(relaunched.release == nil)
    #expect(relaunched.downloadedArchive == nil)
    #expect(!FileManager.default.fileExists(atPath: staged.path))
    #expect(!FileManager.default.fileExists(atPath: metadata.path))
    #expect(FileManager.default.fileExists(atPath: unrelated.path))
  }

  @Test("A future cached update remains available after returning to a compatible OS")
  func preservesIncompatibleArchive() throws {
    let fixture = try UpdateFixture()
    defer { fixture.clean() }
    let controller = fixture.controller(systemVersion: "14.0")
    let release = try fixture.release(minimum: "14.0")
    try controller.stageArchive(at: fixture.archive, release: release)
    let staged = try #require(controller.downloadedArchive)
    let metadata = staged.deletingLastPathComponent().appendingPathComponent("release.json")

    #expect(fixture.controller(systemVersion: "13.0").downloadedArchive == nil)
    #expect(FileManager.default.fileExists(atPath: staged.path))
    #expect(FileManager.default.fileExists(atPath: metadata.path))
    #expect(fixture.controller(systemVersion: "14.0").downloadedArchive == staged)
  }

  @Test("Disabled automatic checks and smoke launches make no request; manual checks remain explicit")
  func noAutomaticNetworking() async throws {
    let fixture = try UpdateFixture()
    defer { fixture.clean() }
    let release = try fixture.release()
    await UpdateNetwork.shared.reset(feed: fixture.feed(release))
    fixture.defaults.set(false, forKey: "updates.checkAutomatically")
    let disabled = fixture.controller()
    disabled.start()
    try await Task.sleep(for: .milliseconds(50))
    #expect(await UpdateNetwork.shared.requestCount == 0)
    #expect(!disabled.automaticallyDownload)
    disabled.checkNow()
    #expect(await waitUntil { disabled.release == release && !disabled.isChecking })
    #expect(await UpdateNetwork.shared.requestCount == 1)
    #expect(disabled.downloadedArchive == nil)
    disabled.stop()

    fixture.defaults.set(true, forKey: "updates.checkAutomatically")
    let smoke = fixture.controller(automaticChecksAllowed: false)
    smoke.start()
    try await Task.sleep(for: .milliseconds(50))
    #expect(await UpdateNetwork.shared.requestCount == 1)
    smoke.stop()
    let development = fixture.controller(isProduction: false)
    development.start()
    development.checkNow()
    try await Task.sleep(for: .milliseconds(50))
    #expect(await UpdateNetwork.shared.requestCount == 1)
    #expect(!development.isAvailable)
    development.stop()
  }

  @Test("An enabled automatic download verifies and stages without invoking the installer")
  func automaticDownload() async throws {
    let fixture = try UpdateFixture()
    defer { fixture.clean() }
    let release = try fixture.release()
    await UpdateNetwork.shared.reset(feed: fixture.feed(release), archive: fixture.payload)
    fixture.defaults.set(true, forKey: "updates.automaticallyDownload")
    let controller = fixture.controller()
    var installations = 0
    controller.installRelease = { _, _ in installations += 1 }
    controller.start()
    #expect(await waitUntil { controller.downloadedArchive != nil && !controller.isDownloading })
    #expect(await UpdateNetwork.shared.requestCount == 2)
    #expect(controller.progress == 1)
    #expect(installations == 0)
    controller.stop()
    #expect(installations == 0)
    #expect(fixture.controller().downloadedArchive != nil)
  }

  @Test("Automatic download persists separately and disabling it retains the staged archive")
  func independentPreferences() throws {
    let fixture = try UpdateFixture()
    defer { fixture.clean() }
    let controller = fixture.controller()
    #expect(controller.checkAutomatically && !controller.automaticallyDownload)
    controller.checkAutomatically = false
    controller.automaticallyDownload = true
    #expect(!fixture.controller().checkAutomatically && fixture.controller().automaticallyDownload)
    try controller.stageArchive(at: fixture.archive, release: fixture.release())
    let staged = controller.downloadedArchive
    controller.automaticallyDownload = false
    #expect(controller.downloadedArchive == staged)
    #expect(fixture.controller().downloadedArchive == staged)
  }

  private func waitUntil(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<200 {
      if condition() { return true }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
  }
}

@MainActor
private final class UpdateFixture {
  let key = Curve25519.Signing.PrivateKey()
  let payload = Data("PK\u{03}\u{04}signed archive fixture".utf8)
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("TrayNook-Updates-\(UUID().uuidString)")
  let suite = "TrayNook-Updates-\(UUID().uuidString)"
  let defaults: UserDefaults
  var archive: URL { root.appendingPathComponent("input.zip") }

  init() throws {
    defaults = UserDefaults(suiteName: suite)!
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try payload.write(to: archive)
  }

  func clean() {
    defaults.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(at: root)
  }

  func release(version: String = "1.1.0", build: String = "2", minimum: String = "13.0",
    address: String? = nil, signingKey: Curve25519.Signing.PrivateKey? = nil) throws -> UpdateRelease {
    UpdateRelease(version: version, build: build, minimumSystemVersion: minimum, notes: "A small & safe update.",
      archiveURL: URL(string: address ?? "https://github.com/TrayNook/traynook/releases/download/v\(version)/TrayNook-\(version).zip")!,
      signature: try (signingKey ?? key).signature(for: payload).base64EncodedString(), size: payload.count)
  }

  func controller(isProduction: Bool = true, automaticChecksAllowed: Bool = true,
    currentVersion: String = "1.0.0", currentBuild: String = "1", systemVersion: String = "13.0") -> UpdateController {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [UpdateURLProtocol.self]
    return UpdateController(publicKey: key.publicKey.rawRepresentation.base64EncodedString(),
      currentVersion: currentVersion, currentBuild: currentBuild, systemVersion: systemVersion, isProduction: isProduction,
      automaticChecksAllowed: automaticChecksAllowed, cacheDirectory: root.appendingPathComponent("cache"),
      defaults: defaults, session: URLSession(configuration: configuration))
  }

  func feed(_ release: UpdateRelease) -> Data {
    Data("""
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
    <description><![CDATA[\(release.notes)]]></description>
    <sparkle:minimumSystemVersion>\(release.minimumSystemVersion)</sparkle:minimumSystemVersion>
    <enclosure url="\(release.archiveURL.absoluteString)" length="\(release.size)" type="application/octet-stream"
      sparkle:version="\(release.build)" sparkle:shortVersionString="\(release.version)" sparkle:edSignature="\(release.signature)"/>
    </item></channel></rss>
    """.utf8)
  }
}

private actor UpdateNetwork {
  static let shared = UpdateNetwork()
  private(set) var requestCount = 0
  private var feed = Data()
  private var archive = Data()
  func reset(feed: Data, archive: Data = Data()) {
    requestCount = 0
    self.feed = feed
    self.archive = archive
  }
  func response(for url: URL) -> Data {
    requestCount += 1
    return url.pathExtension == "zip" ? archive : feed
  }
}

// URLProtocol owns its thread safety; this stateless subclass keeps all shared fixture state in an actor.
private final class UpdateURLProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    Task {
      let data = await UpdateNetwork.shared.response(for: request.url!)
      let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/xml", "Content-Length": "\(data.count)"])!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    }
  }
  override func stopLoading() {}
}
