import SwiftUI

struct MetricsView: View {
    var body: some View {
        NavigationStack {
            List {
                NavigationLink("Resting Heart Rate") {
                    MetricDetailView(metricName: "Resting Heart Rate")
                }
                NavigationLink("Sleep") {
                    MetricDetailView(metricName: "Sleep")
                }
            }
            .navigationTitle("Metrics")
        }
    }
}

struct MetricDetailView: View {
    let metricName: String

    var body: some View {
        List {
            Section("Summary") {
                Text("\(metricName) detail placeholder")
            }
            Section("Provenance") {
                Text("Source and lineage placeholder")
            }
            Section("Export") {
                Text("Export action placeholder")
            }
        }
        .navigationTitle(metricName)
    }
}
