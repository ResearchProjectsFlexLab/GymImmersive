import SwiftUI

@main
struct GymImmersiveApp: App {
    @State private var appModel = AppModel()
    @State private var immersionStyle: ImmersionStyle = .full

    var body: some Scene {
        WindowGroup(id: AppModel.startWindowID) {
            StartView()
                .environment(appModel)
        }
        .windowResizability(.contentSize)

        ImmersiveSpace(id: AppModel.immersiveSpaceID) {
            ImmersiveGymView()
                .environment(appModel)
        }
        .immersionStyle(selection: $immersionStyle, in: .full)
    }
}
