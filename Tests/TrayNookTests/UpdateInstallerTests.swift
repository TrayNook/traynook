import Foundation
import Sparkle
import Testing

@testable import TrayNook

@Suite("Approved update handoff", .serialized)
@MainActor
struct UpdateInstallerTests {
  @Test("The cached feed preserves signed metadata and escapes release text")
  func feedMetadata() throws {
    let release = fixtureRelease(size: 10)
    let local = URL(string: "http://127.0.0.1:12345/secret/TrayNook.zip")!
    let xml = CachedUpdateServer.appcast(release, archiveURL: local)
    #expect(xml.contains("sparkle:format=\"plain-text\""))
    #expect(xml.contains("&lt;script&gt; &amp; &quot;notes&quot;"))
    #expect(xml.contains("sparkle:edSignature=\"\(release.signature)\""))
    #expect(xml.contains("length=\"10\""))
    // Substitute only the transport address to exercise the same production parser.
    let publicXML = xml.replacingOccurrences(of: local.absoluteString, with: release.archiveURL.absoluteString)
    #expect(try UpdateController.parseFeed(Data(publicXML.utf8)) == [release])
  }

  @Test("Loopback serves only the approved archive and tokenized feed", .timeLimit(.minutes(1)))
  func cachedTransport() async throws {
    let files = FileManager.default
    let directory = files.temporaryDirectory.appendingPathComponent("traynook-update-server-\(UUID())")
    try files.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: directory) }
    let archive = directory.appendingPathComponent("fixture.zip")
    let bytes = Data((0..<200_000).map { UInt8($0 % 251) })
    try bytes.write(to: archive)
    let release = fixtureRelease(size: bytes.count)
    let server = try CachedUpdateServer(release: release, archive: archive)
    defer { server.stop() }
    #expect(server.feedURL == nil)
    try await server.start()
    let feed = try #require(server.feedURL)
    #expect(feed.host == "127.0.0.1")
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: feed)
    request.timeoutInterval = 5
    let (data, response) = try await session.data(for: request)
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    #expect(String(decoding: data, as: UTF8.self).contains("sparkle:edSignature=\"\(release.signature)\""))
    request.url = feed.deletingLastPathComponent().appendingPathComponent("TrayNook.zip")
    let (download, archiveResponse) = try await session.data(for: request)
    #expect((archiveResponse as? HTTPURLResponse)?.statusCode == 200)
    #expect(download == bytes)
    request.url = URL(string: "/appcast.xml", relativeTo: feed)!
    let (unknown, missing) = try await session.data(for: request)
    #expect((missing as? HTTPURLResponse)?.statusCode == 404)
    #expect(unknown.isEmpty)
    request.url = feed
    request.httpMethod = "POST"
    let (_, post) = try await session.data(for: request)
    #expect((post as? HTTPURLResponse)?.statusCode == 404)
  }

  @Test("Missing, wrong-size and symlink archives cannot start the handoff")
  func invalidCache() throws {
    let files = FileManager.default
    let directory = files.temporaryDirectory.appendingPathComponent("traynook-update-invalid-\(UUID())")
    try files.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: directory) }
    let archive = directory.appendingPathComponent("fixture.zip")
    let release = fixtureRelease(size: 10)
    #expect(throws: (any Error).self) { try CachedUpdateServer(release: release, archive: archive) }
    try Data([1]).write(to: archive)
    #expect(throws: (any Error).self) { try CachedUpdateServer(release: release, archive: archive) }
    try Data(repeating: 1, count: 10).write(to: archive)
    let link = directory.appendingPathComponent("link.zip")
    try files.createSymbolicLink(at: link, withDestinationURL: archive)
    #expect(throws: (any Error).self) { try CachedUpdateServer(release: release, archive: link) }
  }

  @Test("A resumed update must match the exact release approved in this session")
  func resumedApproval() throws {
    let release = fixtureRelease(size: 10)
    let item = try #require(SUAppcastItem(dictionary: ["enclosure": [
      "url": release.archiveURL.absoluteString,
      "sparkle:version": release.build,
      "sparkle:shortVersionString": release.version,
      "sparkle:edSignature": release.signature,
      "length": "10",
    ]]))
    let driver = ApprovedUpdateUserDriver(hostBundle: .main, delegate: nil)
    #expect(!driver.approves(item))
    driver.showReady(toInstallAndRelaunch: { #expect($0 == .skip) })
    driver.approvedRelease = release
    #expect(driver.approves(item))
    driver.showReady(toInstallAndRelaunch: { #expect($0 == .install) })
    driver.approvedRelease = UpdateRelease(version: "1.2.0", build: "3", minimumSystemVersion: "13.0",
      notes: "Next", archiveURL: URL(string: "https://github.com/TrayNook/traynook/releases/download/v1.2.0/TrayNook-1.2.0.zip")!,
      signature: release.signature, size: release.size)
    #expect(!driver.approves(item))
    driver.approvedRelease = UpdateRelease(version: release.version, build: release.build,
      minimumSystemVersion: release.minimumSystemVersion, notes: release.notes, archiveURL: release.archiveURL,
      signature: Data(repeating: 2, count: 64).base64EncodedString(), size: release.size)
    #expect(!driver.approves(item))
  }

  private func fixtureRelease(size: Int) -> UpdateRelease {
    UpdateRelease(version: "1.1.0", build: "2", minimumSystemVersion: "13.0", notes: "<script> & \"notes\"",
      archiveURL: URL(string: "https://github.com/TrayNook/traynook/releases/download/v1.1.0/TrayNook-1.1.0.zip")!,
      signature: Data(repeating: 1, count: 64).base64EncodedString(), size: size)
  }
}
