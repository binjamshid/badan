import SwiftUI

struct HomeView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("Today") {
                    Text("Home summary placeholder")
                    Text("This screen should answer: how am I doing, why, and what changed?")
                }
            }
            .navigationTitle("BADAN")
        }
    }
}
