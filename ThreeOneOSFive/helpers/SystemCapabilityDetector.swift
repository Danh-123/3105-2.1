import Foundation
import UIKit

enum SystemAccessCapability: String, Codable {
    case kernelRW = "Kernel R/W"
    case mcmTraversal = "MCM Traversal"
    case securityScopedMount = "Security Scoped Mount"
    case sandboxRestricted = "Sandbox Restricted"
}

enum SystemCapabilityDetector {
    static var osVersionTuple: (major: Int, minor: Int, patch: Int) {
        AppInfo.versionTuple
    }

    static var osMajor: Int {
        osVersionTuple.major
    }

    static var isIOS17: Bool {
        osMajor == 17
    }

    static var isIOS18: Bool {
        osMajor == 18
    }

    static var isIOS26: Bool {
        osMajor == 26
    }

    static var isIOS27OrLater: Bool {
        osMajor >= 27
    }

    /// True if the current iOS version is fully supported by opa334 kernel exploit (iOS 17.0 - 18.7.1 only).
    static var isKernelExploitSupported: Bool {
        let v = osVersionTuple
        return ExploitSupportPolicy.supportsKernelExploit(major: v.major, minor: v.minor, patch: v.patch)
    }

    /// True if MobileContainerManager traversal via bad_query is viable or safe to attempt (iOS 26.0 - 26.6.1 and iOS 27).
    static var isMCMTraversalViable: Bool {
        if isIOS26 {
            let v = osVersionTuple
            return v.minor < 6 || (v.minor == 6 && v.patch <= 1)
        }
        if isIOS27OrLater {
            // On iOS 27+, mcm_bridge and bad_query dynamic library calls can be safely attempted without kernel crashes
            return true
        }
        return false
    }

    /// Determines the best available access capability for the device.
    static var bestAccessCapability: SystemAccessCapability {
        if isKernelExploitSupported {
            return .kernelRW
        } else if isMCMTraversalViable && !isIOS27OrLater {
            return .mcmTraversal
        } else if isIOS27OrLater {
            return .securityScopedMount
        } else {
            return .sandboxRestricted
        }
    }

    /// Returns human-readable diagnostics for logging and UI.
    static var capabilitySummary: String {
        "iOS \(AppInfo.osVersion) (\(AppInfo.osBuild)) — Mode: \(bestAccessCapability.rawValue)"
    }
}
