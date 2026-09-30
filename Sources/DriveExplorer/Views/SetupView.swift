import SwiftUI

private enum SetupStep: Int, CaseIterable, Identifiable {
    case project, consent, client, signIn, synchronization
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .project: "Enable APIs"
        case .consent: "Configure consent"
        case .client: "Import Desktop client"
        case .signIn: "Sign in"
        case .synchronization: "Verify synchronization"
        }
    }
}

/// Google setup instructions reviewed against the linked official guides on 2026-09-29.
/// Cloud configuration cannot be verified locally; only import, sign-in and synchronization report app observations.
struct SetupView: View {
    @Bindable var model: AppModel
    @State private var step: SetupStep = .project
    @Environment(\.dismissWindow) private var dismissWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "externaldrive.badge.person.crop").font(.largeTitle).foregroundStyle(.tint).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Connect your Google Drive").font(.title.bold())
                    Text("Your project. Your account. Read-only access.").foregroundStyle(.secondary)
                }
            }.padding(24)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(SetupStep.allCases) { item in
                        Button { step = item } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Text("\(item.rawValue + 1)").font(.callout.monospacedDigit().bold()).frame(width: 22)
                                Text(item.title).multilineTextAlignment(.leading)
                            }.padding(9).frame(maxWidth: .infinity, alignment: .leading)
                                .background(step == item ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).accessibilityIdentifier("setupStep\(item.rawValue + 1)")
                            .accessibilityAddTraits(step == item ? [.isSelected] : [])
                    }
                    Spacer()
                    Label("No file changes", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
                    Text("No credentials or tokens belong in chat, screenshots or Git.").font(.caption).foregroundStyle(.secondary)
                }.padding(16).frame(width: 220)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("\(step.rawValue + 1). \(step.title)").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                        stepContent
                        Divider()
                        DisclosureGroup("Troubleshooting") { troubleshooting.padding(.top, 10) }.accessibilityIdentifier("setupTroubleshooting")
                        Text("Instructions checked against Google documentation on September 29, 2026. Cloud screens can change. Use the official links if a label differs.").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(24).textSelection(.enabled)
                }.id(step).accessibilityIdentifier("setupInstructions")
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if model.busy {
                    HStack { ProgressView().controlSize(.small); Text(model.progress.isEmpty ? "Preparing…" : model.progress); Spacer(); Button("Cancel", action: model.cancel).accessibilityIdentifier("setupCancel") }
                }
                if let error = model.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled).accessibilityIdentifier("setupError") }
                if let notice = model.operationNotice { Text(notice).foregroundStyle(.secondary).accessibilityIdentifier("setupNotice") }
                HStack {
                    Text("Client: \(model.hasClient ? "saved" : "needed") · Sign-in: \(model.connected ? "saved" : "needed")").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if let previous = SetupStep(rawValue: step.rawValue - 1) { Button("Back") { step = previous }.accessibilityIdentifier("setupBack") }
                    if let next = SetupStep(rawValue: step.rawValue + 1) { Button("Next") { step = next }.accessibilityIdentifier("setupNext") }
                    else { Button("Return to explorer") { dismissWindow(id: "setup") }.accessibilityIdentifier("setupDone") }
                }
            }.font(.callout).padding(18)
        }.frame(minWidth: 820, minHeight: 700)
        .onAppear { model.setupVisible = true }
        .onDisappear { model.setupVisible = false }
    }
    @ViewBuilder private var stepContent: some View {
        switch step {
        case .project:
            Text("This preview uses your own Google Cloud project. You only need to configure it once. You can keep this guide open beside your browser.")
            instruction("Choose a project", "Open Google Cloud Console. Use the project selector at the top, then New Project. Give it a recognizable name, create it, and select it. If you already have a suitable project, select that one.")
            Link("Open Google Cloud Console", destination: URL(string: "https://console.cloud.google.com/")!)
            instruction("Turn on both APIs", "In APIs & Services → Library, search for Google Drive API and choose Enable. Repeat for Google Drive Activity API. Make sure both are enabled in the same selected project.")
            Link("Google’s Drive setup guide", destination: URL(string: "https://developers.google.com/workspace/drive/api/quickstart/python")!)
            Link("Google’s Drive Activity setup guide", destination: URL(string: "https://developers.google.com/workspace/drive/activity/v2/quickstart/python")!)
            Text("Next advances this guide; it does not check or change your Cloud project.").font(.caption).foregroundStyle(.secondary)
        case .consent:
            instruction("Describe your app", "Open Google Auth platform → Branding → Get Started. Enter an app name (for example, Drive Explorer Personal), your support email, audience and contact email. Review Google’s policy yourself, then create the configuration.")
            instruction("Allow your account", "For a personal Gmail account, choose External. Keep the project in Testing and add the exact Google account you will sign in with under Audience → Test users → Add users → Save. Internal is for eligible Workspace organization projects; an administrator may restrict access.")
            instruction("Declare read-only access", "Under Data Access → Add or Remove Scopes, add these two full scope URLs and save:")
            Text("https://www.googleapis.com/auth/drive.metadata.readonly\nhttps://www.googleapis.com/auth/drive.activity.readonly").font(.caption.monospaced()).textSelection(.enabled)
            Text("External projects in Testing normally issue Drive refresh tokens that expire after seven days. Reconnect when needed; this is a Google testing limit.").font(.callout).foregroundStyle(.secondary)
            Link("Google consent and audience instructions", destination: URL(string: "https://developers.google.com/workspace/guides/configure-oauth-consent")!)
            Link("Google refresh-token expiration rules", destination: URL(string: "https://developers.google.com/identity/protocols/oauth2#expiration")!)
        case .client:
            instruction("Create a Desktop app client", "In Google Auth platform → Clients → Create Client, choose Desktop app. Name it Drive Explorer Mac, create it and download the JSON. Keep the downloaded file on your Mac. No manual redirect URI or web server setup is needed.")
            instruction("Import the downloaded file", "Choose the JSON below. Drive Explorer checks its Desktop-client structure before storing it in macOS Keychain. Do not use a Web application client, service-account key or token file.")
            Button(model.hasClient ? "Replace Desktop client JSON…" : "Import Desktop client JSON…", action: model.importClient).buttonStyle(.borderedProminent).disabled(model.busy).accessibilityIdentifier("importOAuth")
            Label(model.hasClient ? "Desktop configuration saved; Google validity is checked during sign-in." : "No Desktop client has been imported.", systemImage: model.hasClient ? "checkmark.circle" : "circle")
            Text("Replacing a different client removes the saved sign-in. Your local metadata is retained.").font(.caption).foregroundStyle(.secondary)
            Link("Google’s Desktop OAuth instructions", destination: URL(string: "https://developers.google.com/identity/protocols/oauth2/native-app")!)
        case .signIn:
            instruction("Continue in your browser", "Sign in with the account allowed by your project’s audience. Check the app identity and requested read-only access before consenting. Return here after the browser callback. The app waits up to three minutes; cancel and retry if you run out of time.")
            instruction("Select both read-only permissions", "Allow Drive metadata and Drive activity on the consent screen. This preview needs both to connect. If either is missing, the app explains which permission was declined and keeps the previous saved sign-in unchanged. No write permission is requested.")
            Button(model.connected ? "Sign in again…" : "Sign in with Google…", action: model.connect).buttonStyle(.borderedProminent).disabled(model.busy || !model.hasClient).accessibilityIdentifier("connectGoogle")
            if !model.hasClient { Text("Import your Desktop JSON in step 3 to enable sign-in.").foregroundStyle(.secondary) }
            Text(model.connected ? "A sign-in is saved in Keychain. Step 5 checks current access to both APIs." : "No sign-in is saved yet.")
            Text("Google may show a warning for your own unverified test project. Check that the client and project are yours. If access is blocked by organization policy, ask your administrator; changing the client type does not bypass it.").font(.callout).foregroundStyle(.secondary)
        case .synchronization:
            instruction("Build your first local index", "Run synchronization to read accessible file metadata and recent activity. Progress appears below. A large Drive can take time; cancellation retains committed observations and the next refresh resumes where supported.")
            Button("Run synchronization", action: model.sync).buttonStyle(.borderedProminent).disabled(model.busy || !model.connected || model.isDemo).accessibilityIdentifier("setupSync")
            if model.isDemo { Text("You are viewing synthetic demo data. Sign in in step 4 to switch to your account workspace.").foregroundStyle(.secondary) }
            else if model.syncVerified {
                Label("Both API collection stages completed without reported gaps in this session.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text("\(model.files.count.formatted()) indexed items · \(model.events.count.formatted()) loaded source records. Last complete poll: \(displayDate(model.lastSync)).")
            } else {
                Text("Current access is not verified by a completed synchronization in this session.").foregroundStyle(.secondary)
                if let last = model.lastSync { Text("Previously recorded complete poll: \(displayDate(last)).").font(.caption) }
            }
            if !model.isDemo && !model.gaps.isEmpty { ForEach(model.gaps, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) } }
            instruction("Check the evidence", "Compare a few known files with drive.google.com: folder, name, size and available activity. Newest items can mean created, modified or first discovered; the owner is not proof of who uploaded an item. Missing actors and sizes stay unknown.")
            Text("A complete poll is not a complete audit history. Activity starts with seven days under My Drive and accessible Shared Drives; shared-with-me items outside those ancestors can lack activity. The Activity screen loads at most 10,000 cached records.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func instruction(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(title).font(.headline); Text(body).fixedSize(horizontal: false, vertical: true) }
    }
    private var troubleshooting: some View {
        VStack(alignment: .leading, spacing: 12) {
            instruction("API disabled / accessNotConfigured / SERVICE_DISABLED", "Enable both APIs in the project that created this Desktop client. Wait for Google’s change to propagate, then retry synchronization. A partial scan is not a verified connection.")
            instruction("access_denied / 403 during consent", "Check the selected account against Audience → Test users. Review the granted scopes. A Workspace administrator may need to allow this app. A file-level 403 can instead mean the account cannot access that item.")
            instruction("Required read-only permission not granted", "Sign in again and select both Drive metadata and Drive activity permissions. The app checks the returned scopes before replacing tokens. A successful consent screen alone does not prove both APIs are accessible; complete step 5 afterward.")
            instruction("invalid_client / redirect_uri_mismatch", "Create and import a Desktop app client from the intended project. Do not reuse a Web client or manually add a web redirect. The app uses a temporary localhost callback.")
            instruction("invalid_grant / sign-in stops after a week", "Sign in again. Grants can be revoked or expire; External Testing projects normally expire Drive refresh tokens after seven days. Do not change your system clock to work around this.")
            instruction("Browser timeout / couldn’t connect to localhost", "Keep the app open during sign-in. Cancel and start a fresh attempt, completing it within three minutes. Check whether local security software blocks the app’s 127.0.0.1 callback; do not disable protections broadly.")
            instruction("429 / 5xx / partial results", "Temporary API/network failures receive bounded retries. If retries fail, check connectivity and project quotas, then refresh later. Read the specific coverage gaps before using results; unavailable Shared Drives or activity must remain labelled incomplete.")
            Link("Google native-app errors and remedies", destination: URL(string: "https://developers.google.com/identity/protocols/oauth2/native-app#errors")!)
        }.font(.callout)
    }
}
