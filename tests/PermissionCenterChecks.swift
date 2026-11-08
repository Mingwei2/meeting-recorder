import Foundation

/// Run with scripts/check-permissions.sh. These checks never show system dialogs.
@main
enum PermissionCenterChecks {
    static func main() {
        var granted = false
        var requests = 0
        let permissions = PermissionCenter(
            screenAccessPreflight: { granted },
            screenAccessRequest: { requests += 1; return false }
        )

        for _ in 0..<5 { permissions.refresh() }
        precondition(requests == 0, "Passive refresh must never request permission")
        precondition(!permissions.screenGranted)

        for _ in 0..<5 { precondition(!permissions.requestScreenCapture()) }
        precondition(requests == 1, "Repeated Start/Allow clicks must not repeat the system prompt")

        granted = true
        permissions.refresh()
        precondition(permissions.screenGranted, "External permission changes must be detected")
        precondition(permissions.requestScreenCapture())
        precondition(requests == 1, "Existing authorization must not show a prompt")

        granted = false
        permissions.refresh()
        precondition(!permissions.screenGranted)
        precondition(!permissions.requestScreenCapture())
        precondition(requests == 1, "Revocation must not restart a prompt loop")

        let relaunched = PermissionCenter(
            screenAccessPreflight: { granted },
            screenAccessRequest: { requests += 1; return false }
        )
        precondition(!relaunched.requestScreenCapture())
        precondition(requests == 2, "An explicit request after relaunch must still be possible")

        let alreadyGranted = PermissionCenter(
            screenAccessPreflight: { true },
            screenAccessRequest: { preconditionFailure("Already authorized") }
        )
        precondition(alreadyGranted.requestScreenCapture())
        precondition(alreadyGranted.screenGranted)

        var delayedRequests = 0
        let needsRelaunch = PermissionCenter(
            screenAccessPreflight: { false },
            screenAccessRequest: { delayedRequests += 1; return true }
        )
        precondition(needsRelaunch.requestScreenCapture())
        precondition(!needsRelaunch.screenGranted, "Consent alone must not claim current-process access")
        precondition(!needsRelaunch.requestScreenCapture())
        precondition(delayedRequests == 1)
        print("Permission flow checks passed (no system prompts).")
    }
}
