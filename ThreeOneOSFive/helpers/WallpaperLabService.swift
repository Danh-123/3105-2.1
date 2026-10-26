import Foundation
import Darwin

struct WallpaperAccessReport: Equatable {
    let layout: WallpaperPosterLayout
    let descriptorCount: Int
    let customDescriptorCount: Int
    let canInstall: Bool
    let deniedExtensionIdentifiers: [String]
}

enum WallpaperAccessProbe {
    static func probe(
        containerURL: URL,
        rootValidator: WallpaperLayoutScanner.RootValidator,
        requiredExtensionIdentifiers: Set<String>? = nil,
        fileManager: FileManager = .default
    ) throws -> WallpaperAccessReport {
        var layout = try WallpaperLayoutScanner.scan(
            containerURL: containerURL,
            rootValidator: rootValidator,
            fileManager: fileManager
        )
        var descriptorCount = 0
        var customDescriptorCount = 0
        for descriptorDirectory in layout.extensionDescriptorDirectories.values {
            let children = (try? fileManager.contentsOfDirectory(
                at: descriptorDirectory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )) ?? []
            for child in children {
                let name = child.lastPathComponent
                if name.hasPrefix(".") && !name.hasPrefix(".3105-wallpaper-") { continue }
                let values = try? child.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                )
                guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
                descriptorCount += 1
                if WallpaperDescriptorIdentity.isCustom(at: child, fileManager: fileManager) {
                    customDescriptorCount += 1
                }
            }
        }

        let requiredIdentifiers: [String]
        if let requiredExtensionIdentifiers {
            requiredIdentifiers = requiredExtensionIdentifiers.sorted()
        } else if layout.supportsCollections {
            requiredIdentifiers = [WallpaperPosterLayout.collectionsExtension]
        } else {
            requiredIdentifiers = layout.extensionDescriptorDirectories.keys.sorted()
        }
        var deniedIdentifiers: [String] = []
        for identifier in requiredIdentifiers {
            if layout.extensionDescriptorDirectories[identifier] == nil {
                let dynamicDir = layout.storeURL
                    .appendingPathComponent(layout.generation, isDirectory: true)
                    .appendingPathComponent("Extensions", isDirectory: true)
                    .appendingPathComponent(identifier, isDirectory: true)
                    .appendingPathComponent("descriptors", isDirectory: true)
                if (try? fileManager.createDirectory(at: dynamicDir, withIntermediateDirectories: true)) != nil {
                    var updated = layout.extensionDescriptorDirectories
                    updated[identifier] = dynamicDir
                    layout = WallpaperPosterLayout(
                        generation: layout.generation,
                        storeURL: layout.storeURL,
                        extensionDescriptorDirectories: updated
                    )
                } else {
                    deniedIdentifiers.append(identifier)
                }
            }
        }

        for identifier in requiredIdentifiers where !deniedIdentifiers.contains(identifier) {
            guard let descriptorDirectory = layout.extensionDescriptorDirectories[identifier] else {
                continue
            }

            let probeURL = descriptorDirectory.appendingPathComponent(
                ".3105-wallpaper-probe-\(UUID().uuidString)",
                isDirectory: true
            )
            var created = mkdir(probeURL.path, 0o700) == 0
            if !created {
                created = (try? fileManager.createDirectory(at: probeURL, withIntermediateDirectories: false)) != nil
            }
            if created {
                let descriptor = open(
                    probeURL.path,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
                if descriptor >= 0 { close(descriptor) }
                let removed = rmdir(probeURL.path) == 0 || (try? fileManager.removeItem(at: probeURL)) != nil
                if !removed {
                    deniedIdentifiers.append(identifier)
                    try? fileManager.removeItem(at: probeURL)
                }
            } else {
                deniedIdentifiers.append(identifier)
            }
        }

        return WallpaperAccessReport(
            layout: layout,
            descriptorCount: descriptorCount,
            customDescriptorCount: customDescriptorCount,
            canInstall: !requiredIdentifiers.isEmpty
                && deniedIdentifiers.isEmpty,
            deniedExtensionIdentifiers: deniedIdentifiers
        )
    }
}

enum WallpaperDeviceAccessService {
    static func report(
        requiredExtensionIdentifiers: Set<String>? = nil
    ) throws -> WallpaperAccessReport {
#if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--simulate-wallpaper-data") {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "3105-Simulated-PosterBoard",
                isDirectory: true
            )
            let descriptors = root.appendingPathComponent(
                "Library/Application Support/PRBPosterExtensionDataStore/72/Extensions/" +
                    "com.apple.WallpaperKit.CollectionsPoster/descriptors",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: descriptors,
                withIntermediateDirectories: true
            )
            return try WallpaperAccessProbe.probe(
                containerURL: root,
                rootValidator: { $0.standardizedFileURL == root.standardizedFileURL },
                requiredExtensionIdentifiers: requiredExtensionIdentifiers
            )
        }
#endif
        guard let path = ContainerStore.resolveAppContainerPath(
            bundleID: "com.apple.PosterBoard"
        ) else {
            throw WallpaperLabError.accessDenied
        }
        return try BookmarkManager.shared.withSecurityScope(for: path) { scopedURL in
            try WallpaperAccessProbe.probe(
                containerURL: scopedURL,
                rootValidator: { ContainerStore.isApplicationContainerPath($0.path) },
                requiredExtensionIdentifiers: requiredExtensionIdentifiers
            )
        }
    }

    static func install(
        _ package: WallpaperStagedPackage
    ) throws -> (WallpaperInstallReceipt, WallpaperAccessReport) {
        let requiredExtensions = Set(
            package.payload.descriptors.map(\.extensionIdentifier)
        )
        guard let path = ContainerStore.resolveAppContainerPath(
            bundleID: "com.apple.PosterBoard"
        ) else {
            throw WallpaperLabError.accessDenied
        }
        return try BookmarkManager.shared.withSecurityScope(for: path) { scopedURL in
            let currentReport = try WallpaperAccessProbe.probe(
                containerURL: scopedURL,
                rootValidator: { ContainerStore.isApplicationContainerPath($0.path) },
                requiredExtensionIdentifiers: requiredExtensions
            )
            guard currentReport.canInstall else {
                throw WallpaperLabError.accessDenied
            }
            let backupRoot = try WallpaperPackageStore.backupRoot()
            let receipt = try WallpaperInstaller.install(
                payload: package.payload,
                layout: currentReport.layout,
                backupRoot: backupRoot
            )
            do {
                try WallpaperPackageStore.delete(package)
            } catch {
                log("wallpaper: staged package leftover after apply")
            }
            _ = try? WallpaperPackageStore.exportToWorkspace(package)
            let refreshedReport = try WallpaperAccessProbe.probe(
                containerURL: scopedURL,
                rootValidator: { ContainerStore.isApplicationContainerPath($0.path) },
                requiredExtensionIdentifiers: requiredExtensions
            )
            return (receipt, refreshedReport)
        }
    }

    static func resetCustomCollections() throws -> (Int, WallpaperAccessReport) {
        guard let path = ContainerStore.resolveAppContainerPath(
            bundleID: "com.apple.PosterBoard"
        ) else {
            throw WallpaperLabError.accessDenied
        }
        return try BookmarkManager.shared.withSecurityScope(for: path) { scopedURL in
            let currentReport = try WallpaperAccessProbe.probe(
                containerURL: scopedURL,
                rootValidator: { ContainerStore.isApplicationContainerPath($0.path) }
            )
            guard currentReport.canInstall else {
                throw WallpaperLabError.accessDenied
            }
            let backupRoot = try WallpaperPackageStore.backupRoot()
            let removed = try WallpaperInstaller.resetCustomDescriptors(
                layout: currentReport.layout,
                containerURL: scopedURL,
                rootValidator: { ContainerStore.isApplicationContainerPath($0.path) },
                backupRoot: backupRoot
            )
            let refreshedReport = try WallpaperAccessProbe.probe(
                containerURL: scopedURL,
                rootValidator: { ContainerStore.isApplicationContainerPath($0.path) }
            )
            return (removed, refreshedReport)
        }
    }
}

struct WallpaperStagedPackage: Identifiable, Equatable {
    let id: UUID
    let displayName: String
    let repositoryIdentity: String?
    let packageDirectoryURL: URL
    let archiveURL: URL
    let extractedURL: URL
    let payload: TendiesPayload
    let importedAt: Date
}

enum WallpaperPackageStore {
    private static let archiveName = "wallpaper.tendies"
    private static let extractedName = "Extracted"
    private static let metadataName = "metadata.plist"

    static func stagingRoot(fileManager: FileManager = .default) throws -> URL {
        let base = try applicationSupportURL(fileManager: fileManager)
        let url = base.appendingPathComponent("WallpaperLab/Packages", isDirectory: true)
        try createApprovedDirectory(url, fileManager: fileManager)
        return url
    }

    static func backupRoot(fileManager: FileManager = .default) throws -> URL {
        let base = try applicationSupportURL(fileManager: fileManager)
        let url = base.appendingPathComponent("WallpaperLab/Backups", isDirectory: true)
        try createApprovedDirectory(url, fileManager: fileManager)
        return url
    }

    static func exportToWorkspace(
        _ package: WallpaperStagedPackage,
        fileManager: FileManager = .default
    ) throws -> URL {
        let documents = try fileManager.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let sanitizedName = package.displayName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let exportDir = documents
            .appendingPathComponent("Workspace", isDirectory: true)
            .appendingPathComponent("ExportedWallpapers", isDirectory: true)
            .appendingPathComponent(sanitizedName.isEmpty ? "Wallpaper" : sanitizedName, isDirectory: true)

        try fileManager.createDirectory(at: exportDir, withIntermediateDirectories: true)

        let normalizedUUID = "99990000-0000-0000-0000-000000000000"
        let normalizedTarget = exportDir.appendingPathComponent(normalizedUUID, isDirectory: true)

        if fileManager.fileExists(atPath: normalizedTarget.path) {
            try? fileManager.removeItem(at: normalizedTarget)
        }

        if let firstDescriptor = package.payload.descriptors.first {
            try fileManager.copyItem(at: firstDescriptor.directoryURL, to: normalizedTarget)
            try? WallpaperDescriptorRewriter.randomize(
                in: normalizedTarget,
                identifier: 999900,
                fileManager: fileManager
            )
        } else if fileManager.fileExists(atPath: package.extractedURL.path) {
            try fileManager.copyItem(at: package.extractedURL, to: normalizedTarget)
        }

        for descriptor in package.payload.descriptors {
            let descName = descriptor.directoryURL.lastPathComponent
            let dest = exportDir.appendingPathComponent(descName, isDirectory: true)
            if !fileManager.fileExists(atPath: dest.path) {
                try? fileManager.copyItem(at: descriptor.directoryURL, to: dest)
            }
        }

        return exportDir
    }

    static func importPackage(
        from sourceURL: URL,
        displayName: String? = nil,
        repositoryIdentity: String? = nil,
        fileManager: FileManager = .default
    ) throws -> WallpaperStagedPackage {
        guard sourceURL.pathExtension.lowercased() == "tendies" else {
            throw WallpaperLabError.unsupportedPackage
        }
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess { sourceURL.stopAccessingSecurityScopedResource() }
        }
        let values = try sourceURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true else {
            throw WallpaperLabError.symbolicLinkUnsupported
        }
        let size = Int64(values.fileSize ?? 0)
        guard size > 0, size <= WallpaperLabLimits.maximumArchiveBytes else {
            throw WallpaperLabError.packageTooLarge
        }
        let resolvedDisplayName = (
            displayName ?? sourceURL.deletingPathExtension().lastPathComponent
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidMetadataText(resolvedDisplayName, maximumBytes: 255),
              repositoryIdentity.map({
                  isValidMetadataText($0, maximumBytes: 4_096)
              }) ?? true else {
            throw WallpaperLabError.unsupportedPackage
        }

        let root = try stagingRoot(fileManager: fileManager)
        let id = UUID()
        let importingURL = root.appendingPathComponent(
            ".importing-\(id.uuidString)",
            isDirectory: true
        )
        let finalURL = root.appendingPathComponent(id.uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: importingURL,
                withIntermediateDirectories: false
            )
            let archiveURL = importingURL.appendingPathComponent(archiveName)
            try fileManager.copyItem(at: sourceURL, to: archiveURL)
            let extractedURL = importingURL.appendingPathComponent(
                extractedName,
                isDirectory: true
            )
            _ = try SecureZIPArchive.extract(
                archiveURL: archiveURL,
                destinationURL: extractedURL,
                fileManager: fileManager
            )
            _ = try TendiesPackageInspector.inspectExtractedPackage(
                at: extractedURL,
                fileManager: fileManager
            )
            let metadata = PackageMetadata(
                id: id,
                displayName: resolvedDisplayName,
                repositoryIdentity: repositoryIdentity,
                importedAt: Date()
            )
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            try encoder.encode(metadata).write(
                to: importingURL.appendingPathComponent(metadataName),
                options: .atomic
            )
            guard rename(importingURL.path, finalURL.path) == 0 else {
                throw WallpaperLabError.unsafeArchive
            }
            let importedPackage = try loadPackage(
                at: finalURL,
                fileManager: fileManager
            )
            if let repositoryIdentity {
                for existingPackage in packages(fileManager: fileManager)
                where existingPackage.id != importedPackage.id
                    && existingPackage.repositoryIdentity == repositoryIdentity {
                    try? delete(existingPackage, fileManager: fileManager)
                }
            }
            return importedPackage
        } catch let error as WallpaperLabError {
            try? fileManager.removeItem(at: importingURL)
            throw error
        } catch {
            try? fileManager.removeItem(at: importingURL)
            throw WallpaperLabError.unsupportedPackage
        }
    }

    static func packages(fileManager: FileManager = .default) -> [WallpaperStagedPackage] {
        guard let root = try? stagingRoot(fileManager: fileManager),
              let directories = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
              ) else { return [] }
        return directories.compactMap { directory in
            guard UUID(uuidString: directory.lastPathComponent) != nil else { return nil }
            return try? loadPackage(at: directory, fileManager: fileManager)
        }.sorted { $0.importedAt > $1.importedAt }
    }

    static func contains(
        repositoryIdentity: String,
        fileManager: FileManager = .default
    ) -> Bool {
        packages(fileManager: fileManager).contains {
            $0.repositoryIdentity == repositoryIdentity
        }
    }

    static func delete(
        _ package: WallpaperStagedPackage,
        fileManager: FileManager = .default
    ) throws {
        let root = try stagingRoot(fileManager: fileManager)
        guard package.packageDirectoryURL.deletingLastPathComponent().standardizedFileURL
                == root.standardizedFileURL,
              package.packageDirectoryURL.lastPathComponent == package.id.uuidString else {
            throw WallpaperLabError.unsafeArchive
        }
        try WallpaperLayoutScanner.validateDirectory(
            package.packageDirectoryURL,
            fileManager: fileManager
        )
        try fileManager.removeItem(at: package.packageDirectoryURL)
    }

    private static func loadPackage(
        at directory: URL,
        fileManager: FileManager
    ) throws -> WallpaperStagedPackage {
        try WallpaperLayoutScanner.validateDirectory(directory, fileManager: fileManager)
        let metadataData = try Data(contentsOf: directory.appendingPathComponent(metadataName))
        let metadata = try PropertyListDecoder().decode(PackageMetadata.self, from: metadataData)
        guard directory.lastPathComponent == metadata.id.uuidString,
              !metadata.displayName.isEmpty,
              metadata.displayName.utf8.count <= 255 else {
            throw WallpaperLabError.unsupportedPackage
        }
        let archiveURL = directory.appendingPathComponent(archiveName)
        let extractedURL = directory.appendingPathComponent(extractedName, isDirectory: true)
        let payload = try TendiesPackageInspector.inspectExtractedPackage(
            at: extractedURL,
            fileManager: fileManager
        )
        return WallpaperStagedPackage(
            id: metadata.id,
            displayName: metadata.displayName,
            repositoryIdentity: metadata.repositoryIdentity,
            packageDirectoryURL: directory,
            archiveURL: archiveURL,
            extractedURL: extractedURL,
            payload: payload,
            importedAt: metadata.importedAt
        )
    }

    private static func applicationSupportURL(fileManager: FileManager) throws -> URL {
        guard let url = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw WallpaperLabError.accessDenied
        }
        try createApprovedDirectory(url, fileManager: fileManager)
        return url
    }

    private static func createApprovedDirectory(
        _ url: URL,
        fileManager: FileManager
    ) throws {
        if fileManager.fileExists(atPath: url.path) {
            try WallpaperLayoutScanner.validateDirectory(url, fileManager: fileManager)
        } else {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    private static func isValidMetadataText(
        _ value: String,
        maximumBytes: Int
    ) -> Bool {
        !value.isEmpty
            && value.utf8.count <= maximumBytes
            && !value.unicodeScalars.contains(
                where: CharacterSet.controlCharacters.contains
            )
    }
}

private struct PackageMetadata: Codable {
    let id: UUID
    let displayName: String
    let repositoryIdentity: String?
    let importedAt: Date
}
