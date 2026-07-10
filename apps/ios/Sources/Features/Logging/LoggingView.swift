import SwiftUI

struct LoggingView: View {
    var body: some View {
        NavigationStack {
            List {
                Text("Symptoms")
                Text("Medications")
                Text("Food")
                Text("Workout")
            }
            .navigationTitle("Log")
        }
    }
}
