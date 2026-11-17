import SwiftUI

@main
struct PrinceClockInApp: App {
    var body: some Scene {
        MenuBarExtra("PrinceClockIn", systemImage: "clock") {
            Text("PrinceClockIn")
                .padding()
        }
        .menuBarExtraStyle(.window)
    }
}
