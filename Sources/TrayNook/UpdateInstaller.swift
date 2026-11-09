import AppKit
import Network
import Sparkle

@MainActor
final class UpdateInstaller: NSObject, SPUUpdaterDelegate {
  private var updater: SPUUpdater?
  private var driver: ApprovedUpdateUserDriver?
  private var server: CachedUpdateServer?
  private var preparing = false

  // Sparkle is created only after approval: starting its automatic download can install on quit.
  func install(_ release: UpdateRelease, archive: URL) async throws {
    guard !preparing, server == nil else { return }
    preparing = true
    defer { preparing = false }
    let server = try CachedUpdateServer(release: release, archive: archive)
    self.server = server
    do {
      try await server.start()
      if updater == nil {
        let driver = ApprovedUpdateUserDriver(hostBundle: .main, delegate: nil)
        self.driver = driver
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
        updater.automaticallyChecksForUpdates = false
        updater.automaticallyDownloadsUpdates = false
        updater.sendsSystemProfile = false
        self.updater = updater
        try updater.start()
      }
      driver?.approvedRelease = release
      updater?.checkForUpdates()
    } catch {
      server.stop()
      self.server = nil
      updater = nil
      driver = nil
      throw error
    }
  }

  func feedURLString(for updater: SPUUpdater) -> String? { server?.feedURL?.absoluteString }

  func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
    guard server != nil else { throw CancellationError() }
  }

  func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
    server?.stop()
    server = nil
    driver?.approvedRelease = nil
  }
}

@MainActor
final class ApprovedUpdateUserDriver: SPUStandardUserDriver {
  var approvedRelease: UpdateRelease?

  override func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
    reply: @escaping (SPUUserUpdateChoice) -> Void) {
    // Sparkle also calls this for resumed installers, which bypass shouldProceedWithUpdate.
    guard approves(appcastItem) else { reply(.skip); return }
    reply(.install)
  }

  override func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
    reply(approvedRelease == nil ? .skip : .install)
  }

  func approves(_ item: SUAppcastItem) -> Bool {
    guard let approvedRelease,
      let enclosure = item.propertiesDictionary["enclosure"] as? [String: Any] else { return false }
    return item.versionString == approvedRelease.build
      && item.displayVersionString == approvedRelease.version
      && item.contentLength == approvedRelease.size
      && enclosure["sparkle:edSignature"] as? String == approvedRelease.signature
  }
}

/// Serves only the approved, signed archive to Sparkle, without another public download.
@MainActor
final class CachedUpdateServer {
  private let listener: NWListener
  private let release: UpdateRelease
  private let archive: Data
  private let token = UUID().uuidString
  private var connections: [ObjectIdentifier: NWConnection] = [:]
  private var ready: CheckedContinuation<Void, Error>?
  private(set) var feedURL: URL?

  init(release: UpdateRelease, archive: URL) throws {
    try release.validate()
    let values = try archive.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true, values.fileSize == release.size else {
      throw URLError(.fileDoesNotExist)
    }
    self.release = release
    self.archive = try Data(contentsOf: archive, options: .mappedIfSafe)
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    listener = try NWListener(using: parameters)
  }

  func start() async throws {
    try await withCheckedThrowingContinuation { continuation in
      ready = continuation
      listener.stateUpdateHandler = { [weak self] state in
        Task { @MainActor in
          guard let self else { return }
          switch state {
          case .ready:
            guard let port = self.listener.port else { self.stop(); return }
            self.feedURL = URL(string: "http://127.0.0.1:\(port.rawValue)/\(self.token)/appcast.xml")
            self.ready?.resume()
            self.ready = nil
          case .failed(let error):
            self.ready?.resume(throwing: error)
            self.ready = nil
            self.stop()
          case .cancelled:
            self.ready?.resume(throwing: CancellationError())
            self.ready = nil
          default: break
          }
        }
      }
      listener.newConnectionHandler = { [weak self] connection in
        Task { @MainActor in self?.accept(connection) }
      }
      listener.start(queue: .main)
    }
  }

  func stop() {
    ready?.resume(throwing: CancellationError())
    ready = nil
    listener.cancel()
    for connection in connections.values { connection.cancel() }
    connections.removeAll()
  }

  private func accept(_ connection: NWConnection) {
    guard connections.count < 4 else { connection.cancel(); return }
    connections[ObjectIdentifier(connection)] = connection
    connection.start(queue: .main)
    receive(connection, header: Data())
    Task { @MainActor [weak self, weak connection] in
      try? await Task.sleep(for: .seconds(120))
      if let connection { self?.close(connection) }
    }
  }

  private func receive(_ connection: NWConnection, header: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192 - header.count) { [weak self] data, _, complete, error in
      Task { @MainActor in
        guard let self, self.connections[ObjectIdentifier(connection)] != nil else { return }
        let header = header + (data ?? Data())
        if let end = header.range(of: Data("\r\n\r\n".utf8)),
          let request = String(data: header[..<end.lowerBound], encoding: .utf8) {
          self.respond(connection, request: request)
        } else if header.count >= 8_192 || complete || error != nil {
          self.close(connection)
        } else {
          self.receive(connection, header: header)
        }
      }
    }
  }

  private func respond(_ connection: NWConnection, request: String) {
    let line = request.components(separatedBy: "\r\n").first?.split(separator: " ") ?? []
    let body: Data
    let type: String
    let status: String
    if line.count == 3, line[0] == "GET", line[2] == "HTTP/1.1", line[1] == "/\(token)/appcast.xml",
      let base = feedURL?.deletingLastPathComponent() {
      body = Data(Self.appcast(release, archiveURL: base.appendingPathComponent("TrayNook.zip")).utf8)
      type = "application/rss+xml; charset=utf-8"
      status = "200 OK"
    } else if line.count == 3, line[0] == "GET", line[2] == "HTTP/1.1", line[1] == "/\(token)/TrayNook.zip" {
      body = archive
      type = "application/zip"
      status = "200 OK"
    } else {
      body = Data()
      type = "text/plain"
      status = "404 Not Found"
    }
    let header = Data("HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n".utf8)
    connection.send(content: header, completion: .contentProcessed { [weak self] error in
      Task { @MainActor in
        guard let self else { return }
        if error != nil { self.close(connection) }
        else { self.send(body, offset: 0, connection: connection) }
      }
    })
  }

  private func send(_ data: Data, offset: Int, connection: NWConnection) {
    guard connections[ObjectIdentifier(connection)] != nil else { return }
    guard offset < data.count else { close(connection); return }
    let end = min(offset + 65_536, data.count)
    connection.send(content: data.subdata(in: offset..<end), completion: .contentProcessed { [weak self] error in
      Task { @MainActor in
        guard let self else { return }
        if error != nil { self.close(connection) }
        else { self.send(data, offset: end, connection: connection) }
      }
    })
  }

  private func close(_ connection: NWConnection) {
    connections.removeValue(forKey: ObjectIdentifier(connection))
    connection.cancel()
  }

  static func appcast(_ release: UpdateRelease, archiveURL: URL) -> String {
    func xml(_ value: String) -> String {
      value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&apos;")
    }
    return """
    <?xml version="1.0" encoding="utf-8"?>
    <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
    <title>TrayNook</title><item><title>TrayNook \(xml(release.version))</title>
    <sparkle:version>\(xml(release.build))</sparkle:version>
    <sparkle:shortVersionString>\(xml(release.version))</sparkle:shortVersionString>
    <sparkle:minimumSystemVersion>\(xml(release.minimumSystemVersion))</sparkle:minimumSystemVersion>
    <description sparkle:format="plain-text">\(xml(release.notes))</description>
    <enclosure url="\(xml(archiveURL.absoluteString))" length="\(release.size)" type="application/octet-stream"
      sparkle:version="\(xml(release.build))" sparkle:shortVersionString="\(xml(release.version))"
      sparkle:edSignature="\(xml(release.signature))"/>
    </item></channel></rss>
    """
  }
}
