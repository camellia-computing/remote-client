# Platform notes

## Linux display requirements

Desktop capture and input support depend on the active desktop session. X11 is the broadest supported path in this baseline. Wayland behavior depends on the compositor, PipeWire portal, and permissions supplied by the distribution. A login-screen or headless session may require an operator-managed X server and display-manager configuration.

Do not weaken device permissions globally. Add the current user only to narrowly required groups, verify the distribution's package ownership, and restart the session after a permission change. If capture, input, audio, or hardware acceleration fails, collect sanitized logs and open a reproducible issue with the distribution, desktop environment, session type, and GPU stack.

## macOS permissions

The supported macOS product baseline is 10.15 or later. The x86_64 slice is
built for 10.15; the Apple Silicon slice is built for its architecture minimum,
macOS 11.0. CocoaPods and the Flutter Xcode project retain the product baseline,
while Rust and native C/C++ tooling clamp the arm64 slice to 11.0. The universal
package therefore supports 10.15 on Intel and 11.0 on Apple Silicon.

Screen Recording and Accessibility consent is granted by macOS to the exact signed application identity. After replacing or re-signing an application, remove stale consent entries if necessary, reopen Camellia Remote, and grant only the permissions required for the enabled features. Public distribution also requires an appropriate Developer ID signature and notarization; private/internal signing remains valid for controlled environments whose trust policy accepts it.

## Windows privileges and services

Install and service operations may require elevation. Normal interactive use should remain at the caller's standard token. Verify the package digest and signer before approving an elevation prompt. Controlled deployments may use a private Authenticode chain; a public release should use a publicly trusted code-signing identity.

## Mobile background behavior

The supported iOS/iPadOS baseline is 13.0 or later. Android and iOS may suspend networking, capture, or notification delivery according to operating-system policy. Enable background capabilities only when needed and review the permission explanation shown by the platform. Store releases require their own privacy declarations and platform acceptance testing.
