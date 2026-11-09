import Combine
import CryptoKit
import Foundation

struct UpdateRelease: Codable, Equatable, Sendable {
  let version: String
  let build: String
  let minimumSystemVersion: String
  let notes: String
  let archiveURL: URL
  let signature: String
  let size: Int

  static let maximumArchiveSize = 512 * 1_024 * 1_024

  func validate() throws {
    guard Self.versionParts(version, count: 3) != nil,
      Self.buildNumber(build) != nil,
      Self.versionParts(minimumSystemVersion) != nil,
      size > 0, size <= Self.maximumArchiveSize,
      Data(base64Encoded: signature)?.count == 64,
      let components = URLComponents(url: archiveURL, resolvingAgainstBaseURL: false),
      components.scheme == "https", components.host == "github.com", components.port == nil,
      components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
      components.percentEncodedPath == "/TrayNook/traynook/releases/download/v\(version)/TrayNook-\(version).zip"
    else { throw UpdateError.invalidRelease }
  }

  func isNewer(thanVersion currentVersion: String, build currentBuild: String) -> Bool {
    guard let candidate = Self.versionParts(version, count: 3),
      let current = Self.versionParts(currentVersion, count: 3),
      let candidateBuild = Self.buildNumber(build), let installedBuild = Self.buildNumber(currentBuild)
    else { return false }
    return candidateBuild > installedBuild && !candidate.lexicographicallyPrecedes(current)
  }

  func isNewer(thanVersion currentVersion: String, build currentBuild: String, systemVersion: String) -> Bool {
    guard let minimum = Self.versionParts(minimumSystemVersion), let system = Self.versionParts(systemVersion)
    else { return false }
    return isNewer(thanVersion: currentVersion, build: currentBuild) && !system.lexicographicallyPrecedes(minimum)
  }

  private static func buildNumber(_ value: String) -> UInt64? {
    guard value.first != "0", !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
    return UInt64(value)
  }

  private static func versionParts(_ value: String, count: Int? = nil) -> [UInt64]? {
    let parts = value.split(separator: ".", omittingEmptySubsequences: false)
    guard (1...3).contains(parts.count), count == nil || parts.count == count else { return nil }
    var numbers: [UInt64] = []
    for part in parts {
      guard !part.isEmpty, part.count == 1 || part.first != "0",
        part.utf8.allSatisfy({ (48...57).contains($0) }), let number = UInt64(part) else { return nil }
      numbers.append(number)
    }
    return numbers + Array(repeating: 0, count: 3 - numbers.count)
  }
}

private enum UpdateError: LocalizedError {
  case invalidRelease, invalidFeed, invalidResponse, invalidSignature, invalidArchive

  var errorDescription: String? {
    switch self {
    case .invalidRelease: "The update contains invalid release information."
    case .invalidFeed: "The update feed could not be read safely."
    case .invalidResponse: "The update server returned an unexpected response."
    case .invalidSignature: "The update signature could not be verified."
    case .invalidArchive: "The downloaded update is missing or has changed. Download it again."
    }
  }
}

@MainActor
final class UpdateController: ObservableObject {
  static let feedURL = URL(string: "https://github.com/TrayNook/traynook/releases/latest/download/appcast.xml")!
  static let maximumFeedSize = 1_024 * 1_024

  @Published var checkAutomatically: Bool {
    didSet {
      defaults.set(checkAutomatically, forKey: "updates.checkAutomatically")
      if started { scheduleChecks() }
    }
  }
  @Published var automaticallyDownload: Bool {
    didSet { defaults.set(automaticallyDownload, forKey: "updates.automaticallyDownload") }
  }
  @Published private(set) var release: UpdateRelease?
  @Published private(set) var downloadedArchive: URL?
  @Published private(set) var isChecking = false
  @Published private(set) var isDownloading = false
  @Published private(set) var progress = 0.0
  @Published private(set) var message: String?

  var installRelease: ((UpdateRelease, URL) -> Void)?
  var isAvailable: Bool { isProduction && publicKey != nil }

  private let publicKey: Curve25519.Signing.PublicKey?
  private let currentVersion: String
  private let currentBuild: String
  private let systemVersion: String
  private let isProduction: Bool
  private let automaticChecksAllowed: Bool
  private let cacheDirectory: URL
  private let defaults: UserDefaults
  private let session: URLSession
  private var started = false
  private var scheduledChecks: Task<Void, Never>?
  private var manualCheck: Task<Void, Never>?
  private var downloadTask: Task<Void, Never>?
  private var stagedRelease: UpdateRelease?
  private var stagedArchive: URL?

  init(
    publicKey: String? = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
    currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0",
    currentBuild: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0",
    systemVersion: String = "\(ProcessInfo.processInfo.operatingSystemVersion.majorVersion).\(ProcessInfo.processInfo.operatingSystemVersion.minorVersion).\(ProcessInfo.processInfo.operatingSystemVersion.patchVersion)",
    isProduction: Bool = Bundle.main.bundleIdentifier == "io.github.mahenzon.TrayNook",
    automaticChecksAllowed: Bool = !CommandLine.arguments.contains("--smoke-test") && !CommandLine.arguments.contains("--diagnose"),
    cacheDirectory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("io.github.mahenzon.TrayNook/Updates", isDirectory: true),
    defaults: UserDefaults = .standard,
    session: URLSession = .shared
  ) {
    self.publicKey = publicKey.flatMap { Data(base64Encoded: $0) }.flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }
    self.currentVersion = currentVersion
    self.currentBuild = currentBuild
    self.systemVersion = systemVersion
    self.isProduction = isProduction
    self.automaticChecksAllowed = automaticChecksAllowed
    self.cacheDirectory = cacheDirectory
    self.defaults = defaults
    self.session = session
    checkAutomatically = defaults.object(forKey: "updates.checkAutomatically") as? Bool ?? true
    automaticallyDownload = defaults.object(forKey: "updates.automaticallyDownload") as? Bool ?? false
    restoreArchive()
  }

  func start() {
    guard !started else { return }
    started = true
    scheduleChecks()
  }

  func stop() {
    started = false
    scheduledChecks?.cancel()
    scheduledChecks = nil
    manualCheck?.cancel()
    downloadTask?.cancel()
  }

  func checkNow() {
    guard isAvailable else {
      message = "Updates are available in a production build with an update key."
      return
    }
    manualCheck = Task { [weak self] in await self?.check(automatic: false) }
  }

  func download() {
    guard isAvailable, let release, !isDownloading else { return }
    downloadTask = Task { [weak self] in await self?.download(release) }
  }

  func install() {
    guard isAvailable, let release, let downloadedArchive, let installRelease else { return }
    do {
      try verifyArchive(at: downloadedArchive, release: release)
      installRelease(release, downloadedArchive)
    } catch {
      self.downloadedArchive = nil
      message = error.localizedDescription
    }
  }

  private func scheduleChecks() {
    scheduledChecks?.cancel()
    scheduledChecks = nil
    guard started, checkAutomatically, automaticChecksAllowed, isAvailable else { return }
    scheduledChecks = Task { [weak self] in
      while !Task.isCancelled {
        await self?.check(automatic: true)
        do { try await Task.sleep(for: .seconds(24 * 60 * 60)) }
        catch { break }
      }
    }
  }

  private func check(automatic: Bool) async {
    guard isAvailable, !isChecking, !isDownloading,
      !automatic || (checkAutomatically && automaticChecksAllowed), !Task.isCancelled else { return }
    isChecking = true
    message = "Checking for updates…"
    defer { isChecking = false }
    do {
      var request = URLRequest(url: Self.feedURL)
      request.timeoutInterval = 30
      request.cachePolicy = .reloadIgnoringLocalCacheData
      let (bytes, response) = try await session.bytes(for: request)
      guard let http = response as? HTTPURLResponse, http.statusCode == 200,
        response.expectedContentLength <= Self.maximumFeedSize else { throw UpdateError.invalidResponse }
      var data = Data()
      for try await byte in bytes {
        guard data.count < Self.maximumFeedSize else { throw UpdateError.invalidFeed }
        data.append(byte)
      }
      try Task.checkCancellation()
      let releases = try Self.parseFeed(data)
      let found = releases.filter { $0.isNewer(thanVersion: currentVersion, build: currentBuild, systemVersion: systemVersion) }
        .max { UInt64($0.build)! < UInt64($1.build)! }
      guard let found else {
        message = "TrayNook is up to date."
        return
      }
      release = found
      downloadedArchive = stagedRelease == found ? stagedArchive : nil
      message = downloadedArchive == nil ? "An update is available." : "Update downloaded. Ready to install."
      if automaticallyDownload && downloadedArchive == nil && (!automatic || checkAutomatically) {
        await download(found)
      }
    } catch is CancellationError {
      message = nil
    } catch {
      if !Task.isCancelled { message = error.localizedDescription }
    }
  }

  private func download(_ release: UpdateRelease) async {
    guard !isDownloading, !Task.isCancelled else { return }
    isDownloading = true
    progress = 0
    message = "Downloading update…"
    defer { isDownloading = false }
    do {
      try release.validate()
      var request = URLRequest(url: release.archiveURL)
      request.timeoutInterval = 120
      let delegate = DownloadProgress(expectedSize: release.size) { [weak self] value in
        Task { @MainActor in
          if self?.isDownloading == true { self?.progress = value }
        }
      }
      let (temporary, response) = try await session.download(for: request, delegate: delegate)
      defer { try? FileManager.default.removeItem(at: temporary) }
      guard let http = response as? HTTPURLResponse, http.statusCode == 200,
        response.expectedContentLength < 0 || response.expectedContentLength == release.size else {
        throw UpdateError.invalidResponse
      }
      try Task.checkCancellation()
      try stageArchive(at: temporary, release: release)
      progress = 1
      message = "Update downloaded. Ready to install."
    } catch is CancellationError {
      message = nil
    } catch {
      if !Task.isCancelled { message = error.localizedDescription }
    }
  }

  // The only publication point: neither partial downloads nor unverified files reach the installer.
  func stageArchive(at source: URL, release: UpdateRelease) throws {
    try verifyArchive(at: source, release: release)
    let files = FileManager.default
    try files.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    let target = cacheDirectory.appendingPathComponent("TrayNook-\(release.version)-\(release.build)-\(UUID().uuidString).zip")
    do {
      try files.copyItem(at: source, to: target)
      try verifyArchive(at: target, release: release)
      try JSONEncoder().encode(CachedUpdate(release: release, archiveName: target.lastPathComponent))
        .write(to: metadataURL, options: .atomic)
    } catch {
      try? files.removeItem(at: target)
      throw error
    }
    let previous = stagedArchive
    stagedArchive = target
    stagedRelease = release
    self.release = release
    downloadedArchive = target
    if let previous, previous != target { removeCachedArchive(previous) }
  }

  private var metadataURL: URL { cacheDirectory.appendingPathComponent("release.json") }

  private struct CachedUpdate: Codable {
    let release: UpdateRelease
    let archiveName: String
  }

  private func restoreArchive() {
    guard isAvailable,
      let size = try? metadataURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
      size <= Self.maximumFeedSize,
      let data = try? Data(contentsOf: metadataURL), data.count <= Self.maximumFeedSize,
      let cached = try? JSONDecoder().decode(CachedUpdate.self, from: data),
      cached.archiveName == (cached.archiveName as NSString).lastPathComponent,
      cached.archiveName.hasPrefix("TrayNook-"), cached.archiveName.hasSuffix(".zip"),
      (try? cached.release.validate()) != nil
    else { return }
    let archive = cacheDirectory.appendingPathComponent(cached.archiveName)
    if !cached.release.isNewer(thanVersion: currentVersion, build: currentBuild) {
      removeCachedArchive(archive)
      try? FileManager.default.removeItem(at: metadataURL)
      return
    }
    guard cached.release.isNewer(thanVersion: currentVersion, build: currentBuild, systemVersion: systemVersion),
      (try? verifyArchive(at: archive, release: cached.release)) != nil else { return }
    release = cached.release
    stagedRelease = cached.release
    stagedArchive = archive
    downloadedArchive = archive
    message = "Update downloaded. Ready to install."
  }

  private func removeCachedArchive(_ archive: URL) {
    guard archive.deletingLastPathComponent().standardizedFileURL == cacheDirectory.standardizedFileURL,
      archive.lastPathComponent.hasPrefix("TrayNook-"), archive.pathExtension == "zip" else { return }
    try? FileManager.default.removeItem(at: archive)
  }

  private func verifyArchive(at archive: URL, release: UpdateRelease) throws {
    try release.validate()
    guard let publicKey else { throw UpdateError.invalidSignature }
    let values = try archive.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true, values.fileSize == release.size else {
      throw UpdateError.invalidArchive
    }
    let data = try Data(contentsOf: archive, options: .mappedIfSafe)
    guard data.count == release.size, let signature = Data(base64Encoded: release.signature),
      publicKey.isValidSignature(signature, for: data) else { throw UpdateError.invalidSignature }
  }

  static func parseFeed(_ data: Data) throws -> [UpdateRelease] {
    guard data.count <= maximumFeedSize, let xml = String(data: data, encoding: .utf8),
      !xml.localizedCaseInsensitiveContains("<!DOCTYPE"), !xml.localizedCaseInsensitiveContains("<!ENTITY")
    else { throw UpdateError.invalidFeed }
    let delegate = AppcastParser()
    let parser = XMLParser(data: data)
    parser.shouldResolveExternalEntities = false
    parser.delegate = delegate
    guard parser.parse(), !delegate.invalid, !delegate.releases.isEmpty else { throw UpdateError.invalidFeed }
    return delegate.releases
  }
}

private final class DownloadProgress: NSObject, URLSessionDownloadDelegate {
  private let progress: @Sendable (Double) -> Void
  private let expectedSize: Int
  init(expectedSize: Int, _ progress: @escaping @Sendable (Double) -> Void) {
    self.expectedSize = expectedSize
    self.progress = progress
  }
  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
    guard totalBytesWritten <= expectedSize else { downloadTask.cancel(); return }
    progress(min(1, Double(totalBytesWritten) / Double(expectedSize)))
  }
  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

private final class AppcastParser: NSObject, XMLParserDelegate {
  var releases: [UpdateRelease] = []
  var invalid = false
  private var inItem = false
  private var text = ""
  private var notes = ""
  private var minimum = ""
  private var channel = ""
  private var enclosure: [String: String] = [:]

  func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
    text = ""
    if elementName == "rss", attributeDict["xmlns:sparkle"] != "http://www.andymatuschak.org/xml-namespaces/sparkle" {
      invalid = true
      parser.abortParsing()
    }
    if elementName == "item" {
      guard !inItem, releases.count < 128 else { invalid = true; parser.abortParsing(); return }
      inItem = true
      notes = ""; minimum = ""; channel = ""; enclosure = [:]
    } else if inItem, elementName == "enclosure" {
      guard enclosure.isEmpty else { invalid = true; parser.abortParsing(); return }
      enclosure = attributeDict
    }
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
  func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
    if let value = String(data: CDATABlock, encoding: .utf8) { text += value }
    else { invalid = true; parser.abortParsing() }
  }

  func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
    guard inItem else { return }
    switch elementName {
    case "description": notes = text.trimmingCharacters(in: .whitespacesAndNewlines)
    case "sparkle:minimumSystemVersion": minimum = text.trimmingCharacters(in: .whitespacesAndNewlines)
    case "sparkle:channel": channel = text.trimmingCharacters(in: .whitespacesAndNewlines)
    case "item":
      inItem = false
      guard channel.isEmpty || channel == "stable" else { return }
      guard let version = enclosure["sparkle:shortVersionString"], let build = enclosure["sparkle:version"],
        let address = enclosure["url"], let url = URL(string: address),
        let signature = enclosure["sparkle:edSignature"], let length = enclosure["length"], let size = Int(length)
      else { invalid = true; parser.abortParsing(); return }
      let release = UpdateRelease(version: version, build: build, minimumSystemVersion: minimum,
        notes: notes, archiveURL: url, signature: signature, size: size)
      do { try release.validate(); releases.append(release) }
      catch { invalid = true; parser.abortParsing() }
    default: break
    }
  }

  func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { nil }
}
