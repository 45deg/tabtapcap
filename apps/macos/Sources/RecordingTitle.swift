// Chooses the recording name at capture start. Uses available window metadata
// and falls back to the selected audio source and local start time.
import AppKit
import ApplicationServices
import CoreGraphics

enum RecordingTitle {
    @concurrent static func initial(for source: AudioSource, at startedAt: Date) async -> String {
        if case let .application(bundleID, _) = source, let title = windowTitle(for: bundleID) {
            return title
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return source.name + " " + formatter.string(from: startedAt)
    }

    private static func windowTitle(for bundleID: String) -> String? {
        let processes = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map(\.processIdentifier)
        guard let process = processes.first else { return nil }

        // A single process can report its focused or main window even when
        // TabTapCap is frontmost. For multiple instances, use on-screen order.
        if processes.count == 1, let title = accessibilityTitle(for: process) {
            return title
        }

        guard CGPreflightScreenCaptureAccess(),
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }

        for window in windows {
            guard let owner = window[kCGWindowOwnerPID as String] as? pid_t,
                  processes.contains(owner),
                  window[kCGWindowLayer as String] as? Int == 0 else { continue }
            if let title = nonemptyTitle(window[kCGWindowName as String] as? String) {
                return title
            }
        }
        return nil
    }

    private static func accessibilityTitle(for process: pid_t) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let application = AXUIElementCreateApplication(process)

        // Bound IPC to an unresponsive target so metadata cannot stall recording.
        let timeout: Float = 0.1
        guard AXUIElementSetMessagingTimeout(application, timeout) == .success else { return nil }
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(application, attribute as CFString, &value) == .success,
                  let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { continue }
            let window = value as! AXUIElement
            guard AXUIElementSetMessagingTimeout(window, timeout) == .success else { continue }

            var title: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success,
               let title = nonemptyTitle(title as? String) {
                return title
            }
        }
        return nil
    }

    private static func nonemptyTitle(_ value: String?) -> String? {
        guard let title = value?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        return title
    }
}
