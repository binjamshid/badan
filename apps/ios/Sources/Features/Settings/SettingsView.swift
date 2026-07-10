import SwiftUI

struct SettingsView: View {
    var body: some View {
        NavigationStack {
            List {
                Text("Sources")
                Text("Exports")
                Text("Appearance")
                Text("Language")
            }
            .navigationTitle("Settings")
        }
    }
}
