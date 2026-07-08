import SwiftUI

/// Window layout: category sidebar + item table.
struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 190, ideal: 230)
        } detail: {
            DetailView()
        }
        .navigationTitle("RepoMen")
    }
}
