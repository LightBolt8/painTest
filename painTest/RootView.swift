import SwiftUI

struct RootView: View {
    @StateObject private var store = PainStore()
    @ObservedObject private var bridge = BridgeDiscovery.shared
    @AppStorage(ConsentView.storageKey) private var consentAccepted = false
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView()
                .tabItem {
                    Label("Capture", systemImage: "camera.fill")
                }
                .tag(0)

            LogView()
                .tabItem {
                    Label("Log", systemImage: "list.bullet.rectangle")
                }
                .tag(1)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
                .tag(2)
        }
        .animation(AppAnimations.quick, value: selectedTab)
        .environmentObject(store)
        .environmentObject(bridge)
        .task { bridge.start() }
        .fullScreenCover(isPresented: Binding(
            get: { !consentAccepted },
            set: { _ in }
        )) {
            ConsentView { }
        }
    }
}

#Preview {
    RootView()
}
