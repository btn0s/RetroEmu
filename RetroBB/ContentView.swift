import SwiftUI
import Foundation

enum EmulatorError: LocalizedError {
    case coreNotFound
    
    var localizedDescription: String {
        switch self {
        case .coreNotFound:
            return "Could not find the ppsspp_libretro.dylib core."
        }
    }
}

class EmulatorManager: ObservableObject {
    @Published var isRunning = false
    @Published var errorMessage: String?
    private var frontend: LibretroFrontend?
    
    func startEmulator() {
        frontend = LibretroFrontend()
        
        do {
            guard let corePath = Bundle.main.path(forResource: "ppsspp_libretro", ofType: "dylib", inDirectory: "Frameworks") else {
                throw EmulatorError.coreNotFound
            }

            try frontend?.setupCore(at: corePath)

            frontend?.runCore()
            isRunning = true
            errorMessage = nil
        } catch {
            print("Error starting emulator: \(error)")
            errorMessage = error.localizedDescription
        }
    }
    
    func stopEmulator() {
//        frontend?.unloadGame()
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
                .defaultButtonStyle()
            } else {
                Text("Emulator is not running")
                    .font(.headline)
                Button("Start Emulator") {
                    emulatorManager.startEmulator()
                }
                .defaultButtonStyle()
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
