import SwiftUI
import UniformTypeIdentifiers

struct FolderMountSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appLanguage) private var language
    @ObservedObject private var bookmarkManager = BookmarkManager.shared
    @State private var isShowingPicker = false
    @State private var errorMessage: String?
    @State private var isShowingError = false
    var onFolderMounted: ((URL) -> Void)? = nil

    var body: some View {
        NavigationStack {
            List {
                systemCapabilitySection
                actionsSection
                mountedFoldersSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle(language.text("mount.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(language.text("common.done")) {
                        dismiss()
                    }
                }
            }
            .fileImporter(
                isPresented: $isShowingPicker,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                handlePickerResult(result)
            }
            .alert(
                language.text("common.failed"),
                isPresented: $isShowingError,
                actions: {
                    Button(language.text("common.done"), role: .cancel) { }
                },
                message: {
                    Text(errorMessage ?? "")
                }
            )
        }
    }

    private var systemCapabilitySection: some View {
        Section {
            HStack(spacing: 12) {
                AppRowIcon(systemName: "cpu", tint: AppTheme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("iOS \(AppInfo.osVersion) (\(AppInfo.osBuild))")
                        .font(.subheadline.weight(.semibold))
                    Text(SystemCapabilityDetector.capabilitySummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(SystemCapabilityDetector.bestAccessCapability.rawValue)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(AppTheme.accent.opacity(0.14))
                    .foregroundStyle(AppTheme.accent)
                    .clipShape(Capsule())
            }
            .padding(.vertical, 2)
        } header: {
            Text(language.text("mount.system_capability"))
        } footer: {
            Text(language.text("mount.capability_footer"))
        }
    }

    private var actionsSection: some View {
        Section {
            Button {
                quickMountWorkspace()
            } label: {
                Label(language.text("mount.quick_workspace"), systemImage: "bolt.fill")
                    .foregroundStyle(.orange)
            }

            Button {
                isShowingPicker = true
            } label: {
                Label(language.text("mount.add_folder"), systemImage: "folder.badge.plus")
                    .foregroundStyle(AppTheme.accent)
            }

            Button {
                bookmarkManager.activateAllBookmarks()
            } label: {
                Label(language.text("mount.refresh"), systemImage: "arrow.clockwise")
            }
        } header: {
            Text(language.text("mount.actions"))
        } footer: {
            Text(language.text("mount.quick_workspace_footer"))
        }
    }

    private var mountedFoldersSection: some View {
        Section {
            if bookmarkManager.mountedFolders.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "folder.badge.questionmark")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(language.text("mount.empty_title"))
                            .font(.subheadline.weight(.medium))
                        Text(language.text("mount.empty_message"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            } else {
                ForEach(bookmarkManager.mountedFolders) { folder in
                    HStack(spacing: 12) {
                        AppRowIcon(
                            systemName: folder.isAccessible ? "folder.fill" : "folder.badge.gearshape",
                            tint: folder.isAccessible ? AppTheme.accent : .orange
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(folder.name)
                                .font(.subheadline.weight(.semibold))
                            Text(folder.path)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        if folder.isAccessible {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.subheadline)
                                .foregroundStyle(.green)
                                .accessibilityLabel("Active")
                        } else {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.subheadline)
                                .foregroundStyle(.orange)
                                .accessibilityLabel("Inactive")
                        }
                    }
                    .padding(.vertical, 2)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            bookmarkManager.removeBookmark(id: folder.id)
                        } label: {
                            Label(language.text("browser.delete"), systemImage: "trash")
                        }
                    }
                }
            }
        } header: {
            Text(String(format: language.text("mount.mounted_folders"), BookmarkManager.shared.mountedFolders.count))
        } footer: {
            if !bookmarkManager.mountedFolders.isEmpty {
                Text(language.text("mount.mounted_footer"))
            }
        }
    }

    private func handlePickerResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                _ = try bookmarkManager.saveBookmark(for: url)
                onFolderMounted?(url)
                if onFolderMounted != nil {
                    dismiss()
                }
            } catch {
                errorMessage = error.localizedDescription
                isShowingError = true
            }
        case .failure(let error):
            errorMessage = error.localizedDescription
            isShowingError = true
        }
    }

    private func quickMountWorkspace() {
        do {
            let docs = try FileManager.default.url(
                for: .documentDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let workspace = docs.appendingPathComponent("Workspace", isDirectory: true)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            _ = try bookmarkManager.saveBookmark(for: workspace, customName: "3105 Workspace")

            // Prepare PosterBoard iOS 27 workspace fallback
            _ = try? WallpaperInstaller.prepareIOS27WorkspaceFallbackContainerIfNeeded()

            onFolderMounted?(workspace)
            if onFolderMounted != nil {
                dismiss()
            }
        } catch {
            errorMessage = error.localizedDescription
            isShowingError = true
        }
    }
}
