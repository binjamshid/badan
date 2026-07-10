import SwiftUI
import UIKit

/// A thin SwiftUI wrapper over `UIActivityViewController` so an export's file URLs can be
/// handed to the system share sheet (AirDrop, Files, Mail, …). Fully offline: it only ever
/// receives on-device file URLs — BADAN makes no network calls on this path.
struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    var applicationActivities: [UIActivity]? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: applicationActivities)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
