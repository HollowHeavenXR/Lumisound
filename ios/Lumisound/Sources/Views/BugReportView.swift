import SwiftUI
import UIKit

// MARK: - BugReportCategory

enum BugReportCategory: String, CaseIterable, Identifiable {
    case playback
    case library
    case streaming
    case account
    case appearance
    case crash
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .playback:   return "Playback"
        case .library:    return "Library / Import"
        case .streaming:  return "Streaming / Search"
        case .account:    return "Account / Sync"
        case .appearance: return "Appearance"
        case .crash:      return "Crash / Freeze"
        case .other:      return "Other"
        }
    }
}

// MARK: - BugReportView

/// Lets a user describe a problem and send it straight to the server, where it's
/// stored in `ios_bug_reports` for review. Submission works whether or not the
/// user is signed in — `/bug-report` accepts an optional auth token.
struct BugReportView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var account: AccountService

    @State private var category: BugReportCategory = .other
    @State private var description: String = ""
    @State private var contactEmail: String = ""
    @State private var includeLogs: Bool = true
    @State private var isSubmitting = false
    @State private var submitError: String?
    @State private var didSubmit = false

    var body: some View {
        LKPage(title: "Report a Bug", subtitle: "Tell us what happened — logs are attached for you.", icon: "ladybug.fill", tint: .red) {
            LKSection {
                LumiPicker("Category", selection: $category) {
                    ForEach(BugReportCategory.allCases) { cat in
                        Text(cat.displayName).lumiOptionLabel(String(describing: cat.displayName)).tag(cat)
                    }
                }
                .tint(AppTheme.dynamicAccent)
            } header: {
                sectionHeader("What's this about?")
            }

            LKSection {
                TextEditor(text: $description)
                    .frame(minHeight: 140)
                    .foregroundStyle(AppTheme.textPrimary)
                    .overlay(alignment: .topLeading) {
                        if description.isEmpty {
                            Text("What happened? What did you expect instead? Steps to reproduce help a lot.")
                                .font(AppTheme.bodyFont(size: 14))
                                .foregroundStyle(AppTheme.textSecondary)
                                .padding(.top, 8)
                                .padding(.leading, 4)
                                .allowsHitTesting(false)
                        }
                    }
            } header: {
                sectionHeader("Description")
            }

            LKSection {
                TextField("Email (optional)", text: $contactEmail)
                    .foregroundStyle(AppTheme.textPrimary)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                sectionHeader("Contact")
            } footer: {
                Text("Leave blank to stay anonymous. If you're signed in, your account is already linked to the report.")
                    .font(AppTheme.bodyFont(size: 12))
                    .foregroundStyle(AppTheme.textSecondary)
            }

            LKSection {
                Toggle(isOn: $includeLogs) {
                    Label("Include recent activity log", systemImage: "doc.text.magnifyingglass")
                        .foregroundStyle(AppTheme.textPrimary)
                }
                .tint(AppTheme.dynamicAccent)
            } footer: {
                Text("Sends a short list of recent app actions (e.g. \"Switched to Search tab\", \"Started playback\") and recent error logs — helps pinpoint what led up to the issue. No personal data or file contents are included.")
                    .font(AppTheme.bodyFont(size: 12))
                    .foregroundStyle(AppTheme.textSecondary)
            }

            LKSection {
                Button {
                    Task { await submit() }
                } label: {
                    HStack {
                        Spacer()
                        if isSubmitting {
                            ProgressView()
                        } else {
                            Text("Send Report")
                                .fontWeight(.semibold)
                        }
                        Spacer()
                    }
                }
                .disabled(description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmitting)
                .foregroundStyle(.white)
                .listRowBackground(
                    description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? AppTheme.elevatedSurface
                        : AppTheme.dynamicAccent
                )

                if let submitError {
                    Text(submitError)
                        .font(.caption)
                        .foregroundStyle(AppTheme.error)
                }
            }
        }
        .background(GalleryBackgroundView().ignoresSafeArea())
        .navigationTitle("Report a Bug")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Thanks for the report!", isPresented: $didSubmit) {
            Button("OK") { dismiss() }
        } message: {
            Text("Your report has been sent. We read every one — thank you for helping improve Lumisound.")
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(AppTheme.bodyFont(size: 11))
            .foregroundStyle(AppTheme.textSecondary)
            .kerning(0.8)
    }

    private func submit() async {
        isSubmitting = true
        submitError = nil
        defer { isSubmitting = false }

        let body = BugReportPayload(
            category: category.rawValue,
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            contactEmail: contactEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : contactEmail.trimmingCharacters(in: .whitespacesAndNewlines),
            appVersion: DeviceInfo.appVersion,
            deviceInfo: DeviceInfo.summary,
            recentLogs: includeLogs ? await AppLogger.shared.recentActivitySummary() : nil
        )

        do {
            _ = try await account.makeRequest("/bug-report", method: "POST", body: body)
            didSubmit = true
            description = ""
            contactEmail = ""
        } catch let err as AccountError {
            submitError = err.message
        } catch {
            submitError = "Could not send report — check your connection and try again."
        }
    }
}

private struct BugReportPayload: Encodable {
    let category: String
    let description: String
    let contactEmail: String?
    let appVersion: String?
    let deviceInfo: String?
    let recentLogs: String?

    enum CodingKeys: String, CodingKey {
        case category
        case description
        case contactEmail = "contact_email"
        case appVersion   = "app_version"
        case deviceInfo   = "device_info"
        case recentLogs   = "recent_logs"
    }
}
