import SwiftUI

@main
struct MemoretMacApp: App {
    @StateObject private var model = ReceiverModel()

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
        } label: {
            Image(systemName: "waveform")
                .onAppear { model.start() }
        }
        .menuBarExtraStyle(.window)
    }
}
