import SwiftUI
import UIKit

@main
struct FermaxoRacingApp: App {
    @StateObject private var receiver = TelemetryReceiver()

    var body: some Scene {
        WindowGroup {
            DashboardView(receiver: receiver)
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
                .onAppear {
                    UIApplication.shared.isIdleTimerDisabled = true
                    receiver.start()
                }
        }
    }
}
