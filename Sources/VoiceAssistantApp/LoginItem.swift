import AppKit
import CoreServices
import ServiceManagement

/// "Start when I log in" (windows-voice-assistant `StartupRegistration`): Voice Assistant is a login item
/// (SMAppService), so logging in puts it in the menu bar without opening its window. It's applied when it's switched,
/// not saved in settings.json.
public enum LoginItem {
    /// Windows passes it on the Run entry; the Mac's restart passes it too (`AppController.restart`).
    public static let backgroundArgument = "--background"

    /// On: it opens at login. One that waits for approval in System Settings › General › Login Items counts as off
    /// until it's approved.
    public static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Switches it on or off; a failure is logged, and Settings reads `isEnabled` again after. When macOS wants the
    /// item approved, System Settings opens at Login Items.
    public static func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                if SMAppService.mainApp.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
            } else {
                try SMAppService.mainApp.unregister()
            }

            Log.info(enabled ? "starts at login" : "doesn't start at login")
        } catch {
            Log.warn("couldn't change start at login: \(Log.kind(of: error))")
        }
    }

    /// This launch is macOS opening the app at login. A login item gets no arguments (Windows' Run entry passes
    /// `--background`), so the launch's Apple event says. Call it while the app finishes launching.
    @MainActor
    static func launchedAtLogin() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == AEEventID(kAEOpenApplication) else { return false }
        return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
            == OSType(keyAELaunchedAsLogInItem)
    }
}
