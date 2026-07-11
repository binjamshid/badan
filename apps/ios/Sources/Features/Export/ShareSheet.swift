import SwiftUI
import UIKit

/// A thin SwiftUI wrapper over `UIActivityViewController` so an export's file URLs can be
/// handed to the system share sheet (AirDrop, Files, Mail, …). Fully offline: it only ever
/// receives on-device file URLs — BADAN makes no network calls on this path.
struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    var applicationActivities: [UIActivity]? = nil
    /// Invoked once the share sheet is dismissed. `completed` is `true` only when the user
    /// actually finished a share action (AirDrop/Files/Mail/…); `false` on cancel.
    var onComplete: ((Bool) -> Void)? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: applicationActivities)
        controller.completionWithItemsHandler = { _, completed, _, _ in
            onComplete?(completed)
        }
        // UIActivityViewController requires a popover anchor on iPad or presentation silently
        // fails; harmless no-op on the current iPhone-only target (TARGETED_DEVICE_FAMILY = "1").
        if let popover = controller.popoverPresentationController {
            popover.sourceView = controller.view
            popover.sourceRect = CGRect(x: controller.view.bounds.midX, y: controller.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
