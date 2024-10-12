import SwiftUI
import Foundation
import QuartzCore

enum EmulatorError: LocalizedError {
    case coreNotFound
    case assetsCopyFailed(String)
    case gameLoadFailed
    
    var errorDescription: String? {
        switch self {
        case .coreNotFound:
            return "Could not find the ppsspp_libretro.dylib core."
        case .assetsCopyFailed(let reason):
            return "Failed to copy necessary assets: \(reason)"
        case .gameLoadFailed:
            return "Failed to load the game."
        }
    }
}

class EmulatorManager: ObservableObject {
    @Published var isInitialized = false
    @Published var isRunning = false
    @Published var errorMessage: String?
    @Published var isGameLoaded = false
    @Published var logMessages: [String] = []
    private var frontend: LibretroFrontend?
    private let fileManager = FileManager.default
    private var displayLink: CADisplayLink?
    @Published var videoFrame: CGImage?
    
    init() {
        print("Initializing EmulatorManager")
        do {
            try copyAssetsToDocumentsIfNeeded()
        } catch {
            print("Error during initialization: \(error)")
            errorMessage = error.localizedDescription
        }
    }
    
    private func copyAssetsToDocumentsIfNeeded() throws {
        print("Starting copyAssetsToDocumentsIfNeeded()")
        let documentsPath = try fileManager.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        print("Documents path: \(documentsPath.path)")
        
        let ppssppDestPath = documentsPath.appendingPathComponent("PPSSPP")
        print("PPSSPP destination path: \(ppssppDestPath.path)")
        
        if fileManager.fileExists(atPath: ppssppDestPath.path) {
            print("PPSSPP assets already exist in Documents/PPSSPP")
            return
        }
        
        print("Searching for PPSSPP folder in app bundle...")
        guard let ppssppSourcePath = Bundle.main.url(forResource: "PPSSPP", withExtension: nil) else {
            print("PPSSPP folder not found in app bundle")
            printBundleContents()
            throw EmulatorError.assetsCopyFailed("PPSSPP folder not found in app bundle")
        }
        print("PPSSPP folder found at: \(ppssppSourcePath.path)")
        
        do {
            print("Copying PPSSPP folder to Documents...")
            try fileManager.copyItem(at: ppssppSourcePath, to: ppssppDestPath)
            print("PPSSPP directory successfully copied to Documents/PPSSPP")
            printDirectoryContents(ppssppDestPath)
        } catch {
            print("Error copying PPSSPP assets: \(error)")
            throw EmulatorError.assetsCopyFailed(error.localizedDescription)
        }
    }
    
    private func findPPSSPPFolder(in directory: URL) -> URL? {
        print("Searching for PPSSPP folder in: \(directory.path)")
        guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            print("Failed to create enumerator for directory: \(directory.path)")
            return nil
        }
        
        for case let fileURL as URL in enumerator {
            if fileURL.lastPathComponent == "PPSSPP" {
                print("Found PPSSPP folder at: \(fileURL.path)")
                return fileURL
            }
        }
        
        print("PPSSPP folder not found in: \(directory.path)")
        return nil
    }
    
    private func printBundleContents() {
        print("Printing bundle contents:")
        let bundleURL = Bundle.main.bundleURL
        print("Bundle URL: \(bundleURL.path)")
        printDirectoryContents(bundleURL)
    }
    
    private func printDirectoryContents(_ url: URL, indent: String = "") {
        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        } catch {
            print("\(indent)Error listing contents of \(url.path): \(error)")
            return
        }
        
        for fileURL in contents {
            let isDirectory: Bool
            do {
                let resourceValues = try fileURL.resourceValues(forKeys: [.isDirectoryKey])
                isDirectory = resourceValues.isDirectory ?? false
            } catch {
                print("\(indent)Error determining if \(fileURL.path) is a directory: \(error)")
                continue
            }
            
            print("\(indent)\(isDirectory ? "📁" : "📄") \(fileURL.lastPathComponent)")
            if isDirectory {
                printDirectoryContents(fileURL, indent: indent + "  ")
            }
        }
    }
    
    func loadGame() {
        guard let frontend = frontend else {
            errorMessage = "Emulator not initialized"
            return
        }
        
        guard let gamePath = Bundle.main.path(forResource: "gow", ofType: "iso") else {
            errorMessage = "Game file not found in app bundle"
            log("Game file (gow.iso) not found in app bundle")
            return
        }
        
        log("Attempting to load game from path: \(gamePath)")
        if frontend.loadGame(at: gamePath) {
            isGameLoaded = true
            errorMessage = nil
            log("Game loaded successfully")
        } else {
            isGameLoaded = false
            errorMessage = EmulatorError.gameLoadFailed.localizedDescription
            log("Failed to load game")
        }
    }
    
    func startEmulator() {
        print("Starting emulator...")
        DispatchQueue.main.async { [weak self] in
            self?.initializeAndRunEmulator()
        }
    }
    
    private func initializeAndRunEmulator() {
        print("Initializing and running emulator...")
        frontend = LibretroFrontend()
        
        do {
            print("Searching for ppsspp_libretro.dylib core...")
            guard let corePath = Bundle.main.path(forResource: "ppsspp_libretro", ofType: "dylib", inDirectory: "Frameworks") else {
                print("Core not found in Frameworks directory")
                printBundleContents()
                throw EmulatorError.coreNotFound
            }
            print("Core found at: \(corePath)")

            print("Setting up core...")
            try frontend?.setupCore(at: corePath)

            print("Running core...")
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.frontend?.runCore()
            }
            
            isRunning = true
            errorMessage = nil
            print("Emulator started successfully")
        } catch {
            print("Error starting emulator: \(error)")
            errorMessage = error.localizedDescription
        }
    }
    
    func runCore() {
        guard let frontend = frontend, isGameLoaded else {
            errorMessage = "Game not loaded or emulator not initialized"
            return
        }
        
        log("Starting core execution...")
        isRunning = true
        
        frontend.setVideoOutputHandler { [weak self] cgImage in
            self?.videoFrame = cgImage
        }
        
        displayLink = CADisplayLink(target: self, selector: #selector(step))
        displayLink?.add(to: .main, forMode: .common)
    }
    
    @objc private func step(displayLink: CADisplayLink) {
        guard let frontend = frontend else {
            stopEmulator()
            return
        }
        
        frontend.runCore()
    }
    
    func stopEmulator() {
        log("Stopping emulator...")
        displayLink?.invalidate()
        displayLink = nil
        frontend = nil
        isRunning = false
        log("Emulator stopped")
    }
    
    func initializeEmulator() {
        log("Initializing emulator...")
        frontend = LibretroFrontend()
        
        do {
            log("Searching for ppsspp_libretro.dylib core...")
            guard let corePath = Bundle.main.path(forResource: "ppsspp_libretro", ofType: "dylib", inDirectory: "Frameworks") else {
                log("Core not found in Frameworks directory")
                printBundleContents()
                throw EmulatorError.coreNotFound
            }
            log("Core found at: \(corePath)")

            log("Setting up core...")
            try frontend?.setupCore(at: corePath)
            
            isInitialized = true
            errorMessage = nil
            log("Emulator initialized successfully")
        } catch {
            log("Error initializing emulator: \(error)")
            errorMessage = error.localizedDescription
        }
    }
    
    private func log(_ message: String) {
        print(message)
        DispatchQueue.main.async {
            self.logMessages.append(message)
        }
    }
}

struct ContentView: View {
    @StateObject private var emulatorManager = EmulatorManager()
    @State private var showEmulatorDisplay = false
    
    var body: some View {
        VStack {
            Text(emulatorManager.isInitialized ? "Emulator is initialized" : "Emulator is not initialized")
                .font(.headline)
            
            Button("Initialize Emulator") {
                emulatorManager.initializeEmulator()
            }
            .padding()
            .background(Color.blue)
            .foregroundColor(.white)
            .cornerRadius(12)
            .disabled(emulatorManager.isInitialized)
            
            if emulatorManager.isInitialized {
                Button("Load Game") {
                    emulatorManager.loadGame()
                }
                .padding()
                .background(Color.green)
                .foregroundColor(.white)
                .cornerRadius(12)
                .disabled(emulatorManager.isGameLoaded)
            }
            
            if emulatorManager.isGameLoaded {
                Button(emulatorManager.isRunning ? "Stop Emulator" : "Run Game") {
                    if emulatorManager.isRunning {
                        emulatorManager.stopEmulator()
                    } else {
                        emulatorManager.runCore()
                        showEmulatorDisplay = true
                    }
                }
                .padding()
                .background(emulatorManager.isRunning ? Color.red : Color.orange)
                .foregroundColor(.white)
                .cornerRadius(12)
            }
            
            if let errorMessage = emulatorManager.errorMessage {
                Text("Error: \(errorMessage)")
                    .foregroundColor(.red)
                    .padding()
            }
            
            ScrollView {
                LazyVStack(alignment: .leading) {
                    ForEach(emulatorManager.logMessages, id: \.self) { message in
                        Text(message)
                            .font(.system(size: 12, design: .monospaced))
                    }
                }
            }
            .frame(maxHeight: 200)
            .padding()
            .background(Color.black.opacity(0.1))
            .cornerRadius(8)
        }
        .padding()
        .fullScreenCover(isPresented: $showEmulatorDisplay) {
            EmulatorDisplayView(videoFrame: $emulatorManager.videoFrame, isPresented: $showEmulatorDisplay)
        }
    }
}
