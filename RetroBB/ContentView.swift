import SwiftUI
import Foundation

class EmulatorManager: ObservableObject {
    @Published var isRunning = false
    @Published var errorMessage: String?
    private var frontend: LibretroFrontend?
    
    func startEmulator() {
        frontend = LibretroFrontend()
        
        do {
            // Try to find the core in the Frameworks directory
            guard let corePath = Bundle.main.path(forResource: "ppsspp_libretro", ofType: "dylib", inDirectory: "Frameworks") else {
                throw NSError(domain: "EmulatorError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Core not found in app bundle"])
            }

            print("Core found at path: \(corePath)")

            // Find the ROM
            guard let romPath = Bundle.main.path(forResource: "gow", ofType: "iso") else {
                throw NSError(domain: "EmulatorError", code: 2, userInfo: [NSLocalizedDescriptionKey: "ROM not found in app bundle"])
            }

            print("ROM found at path: \(romPath)")

            try frontend?.startEmulator(corePath: corePath, romPath: romPath)
            isRunning = true
            errorMessage = nil
        } catch {
            print("Error starting emulator: \(error)")
            errorMessage = error.localizedDescription
        }
    }
    
    func stopEmulator() {
        frontend?.stopEmulator()
        frontend = nil
        isRunning = false
    }
}

// Reusable Button Modifier for consistent style
struct DefaultButtonStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding()
            .background(Color.blue)
            .foregroundColor(.white)
            .cornerRadius(12)
            .padding(.horizontal, 20) // Extra padding if needed
    }
}

extension View {
    func defaultButtonStyle() -> some View {
        self.modifier(DefaultButtonStyle())
    }
}

struct ContentView: View {
    @StateObject private var emulatorManager = EmulatorManager()
    
    var body: some View {
        VStack {
            if emulatorManager.isRunning {
                Text("Emulator is running")
                    .font(.headline)
                Button("Stop Emulator") {
                    emulatorManager.stopEmulator()
                }
                .defaultButtonStyle() // Apply the default button style
            } else {
                Text("Emulator is not running")
                    .font(.headline)
                Button("Start Emulator") {
                    emulatorManager.startEmulator()
                }
                .defaultButtonStyle() // Apply the default button style
            }
            
            if let errorMessage = emulatorManager.errorMessage {
                Text("Error: \(errorMessage)")
                    .foregroundColor(.red)
                    .padding()
            }
        }
        .padding()
    }
}
