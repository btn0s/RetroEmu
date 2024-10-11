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
    private let fileManager = FileManager.default
    
    func copyAssetsToDocuments(completion: @escaping (Bool) -> Void) {
        // Path to the PPSSPP folder in the app bundle
        guard let bundlePPSSPPPath = Bundle.main.resourcePath?.appending("/PPSSPP") else {
            print("Could not find PPSSPP assets in bundle")
            completion(false)
            return
        }
        
        // Path to the Documents directory in the app sandbox
        let documentsPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first!
        
        // Destination for the PPSSPP assets in the Documents directory
        let destinationPath = documentsPath.appending("/system/PPSSPP")
        
        // Check if assets are already copied
        if fileManager.fileExists(atPath: destinationPath) {
            print("PPSSPP assets already exist")
            completion(true) // Assets are already in place
            return
        }
        
        // Perform the copy in background
        DispatchQueue.global(qos: .background).async {
            do {
                try self.fileManager.copyItem(atPath: bundlePPSSPPPath, toPath: destinationPath)
                print("PPSSPP assets successfully copied to Documents directory")
                completion(true) // Copying successful
            } catch {
                print("Error copying PPSSPP assets: \(error)")
                completion(false) // Copying failed
            }
        }
    }
    
    func startEmulator() {
        copyAssetsToDocuments { [weak self] success in
            guard success else {
                self?.errorMessage = "Failed to copy necessary assets"
                return
            }
            
            // Now proceed to initialize and run the emulator
            DispatchQueue.main.async { [weak self] in
                self?.initializeAndRunEmulator()
            }
        }
    }
    
    private func initializeAndRunEmulator() {
        frontend = LibretroFrontend()
        
        do {
            guard let corePath = Bundle.main.path(forResource: "ppsspp_libretro", ofType: "dylib", inDirectory: "Frameworks") else {
                throw EmulatorError.coreNotFound
            }

            try frontend?.setupCore(at: corePath)

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.frontend?.runCore()
            }
            
            isRunning = true
            errorMessage = nil
        } catch {
            print("Error starting emulator: \(error)")
            errorMessage = error.localizedDescription
        }
    }
    
    func stopEmulator() {
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
