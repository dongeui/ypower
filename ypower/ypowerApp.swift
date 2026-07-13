import SwiftUI

@main
struct ypowerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private var viewModel = MenuBarViewModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(viewModel: viewModel)
        } label: {
            MenuBarLabel(state: viewModel.connectionState, medium: viewModel.currentMedium)
        }
        .menuBarExtraStyle(.window)
    }
}
