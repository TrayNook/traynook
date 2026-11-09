import SwiftUI

struct UpdateSettingsView: View {
  @ObservedObject var updates: UpdateController

  var body: some View {
    GroupBox(L("Updates")) {
      VStack(alignment: .leading, spacing: 10) {
        Toggle(L("Check for updates automatically"), isOn: $updates.checkAutomatically)
          .disabled(!updates.isAvailable)
        Text(L("Checks at launch and once a day."))
          .font(.caption).foregroundStyle(.secondary)
        Toggle(L("Automatically download updates"), isOn: $updates.automaticallyDownload)
          .disabled(!updates.isAvailable)
        Text(L("Updates install only after you choose Install & Relaunch."))
          .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        if updates.isAvailable {
          HStack {
            Button(L("Check Now")) { updates.checkNow() }
              .disabled(updates.isChecking || updates.isDownloading)
            if updates.isChecking && !updates.isDownloading {
              ProgressView().controlSize(.small).accessibilityLabel(L("Checking for updates…"))
            }
            Spacer()
            if let release = updates.release {
              Text(String(format: L("Version %@ (%@) is available."), release.version, release.build))
                .font(.callout).foregroundStyle(.secondary)
              if updates.downloadedArchive != nil {
                Button(L("Install & Relaunch")) { updates.install() }
                  .disabled(updates.isChecking || updates.isDownloading)
              } else {
                Button(L("Download Update")) { updates.download() }
                  .disabled(updates.isChecking || updates.isDownloading)
              }
            }
          }
          if updates.isDownloading {
            ProgressView(value: updates.progress)
              .accessibilityLabel(L("Downloading update…"))
          }
          if let message = updates.message {
            Text(L(message)).font(.callout).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
          }
          if let release = updates.release, !release.notes.isEmpty {
            DisclosureGroup(L("Release notes")) {
              Text(verbatim: release.notes)
                .font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled).padding(.top, 6)
            }
          }
        } else {
          Text(L("Updates are unavailable in this build."))
            .font(.callout).foregroundStyle(.secondary)
          Link(L("Download the Latest Release…"), destination: URL(string: "https://github.com/TrayNook/traynook/releases/latest")!)
        }
      }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
    }
  }
}
