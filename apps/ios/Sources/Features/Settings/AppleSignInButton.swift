import AuthenticationServices
import SwiftUI

/// Apple's own Sign in with Apple button, with BADAN's action behind it (ADR-0014 / D-44).
///
/// A `UIViewRepresentable` around `ASAuthorizationAppleIDButton` rather than SwiftUI's
/// `SignInWithAppleButton`. Both render the same Apple-supplied artwork, which the Human Interface
/// Guidelines require and which is not something to approximate with a custom label — but
/// `SignInWithAppleButton` insists on owning the request and the completion, which would move the
/// nonce generation and the token handling into the view layer and duplicate what
/// `AppleSignInController` already does and `AccountController` already tests.
///
/// This way the branding is Apple's and the flow is ours, with one entry point
/// (`AccountController.signIn()`) that a test can drive with a fake provider.
struct AppleSignInButton: UIViewRepresentable {
    /// The HIG requires the button to read correctly against its background in both appearances,
    /// and `authorizationButtonStyle` is fixed at construction — so a scheme change rebuilds the
    /// button rather than restyling it. Hosting it in a container is what makes that possible
    /// without SwiftUI tearing down the whole representable.
    @Environment(\.colorScheme) private var colorScheme

    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .clear
        context.coordinator.install(in: container, style: style)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        // Re-captured on every update. Without this, the coordinator would keep calling the closure
        // it was built with — the classic `UIViewRepresentable` staleness bug, and one that here
        // would silently stop sign-in working after any parent state change.
        context.coordinator.action = action
        context.coordinator.install(in: container, style: style)
    }

    private var style: ASAuthorizationAppleIDButton.Style {
        colorScheme == .dark ? .white : .black
    }

    @MainActor
    final class Coordinator: NSObject {
        var action: () -> Void
        private var button: ASAuthorizationAppleIDButton?
        private var installedStyle: ASAuthorizationAppleIDButton.Style?

        init(action: @escaping () -> Void) { self.action = action }

        /// Idempotent: rebuilds only when the style actually changed, so an ordinary SwiftUI update
        /// does not replace a live view mid-tap.
        func install(in container: UIView, style: ASAuthorizationAppleIDButton.Style) {
            guard installedStyle != style else { return }
            button?.removeFromSuperview()

            let fresh = ASAuthorizationAppleIDButton(authorizationButtonType: .signIn,
                                                     authorizationButtonStyle: style)
            fresh.translatesAutoresizingMaskIntoConstraints = false
            fresh.addTarget(self, action: #selector(tapped), for: .touchUpInside)
            container.addSubview(fresh)
            NSLayoutConstraint.activate([
                fresh.topAnchor.constraint(equalTo: container.topAnchor),
                fresh.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                fresh.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                fresh.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ])
            button = fresh
            installedStyle = style
        }

        @objc func tapped() { action() }
    }
}
