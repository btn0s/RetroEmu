import SwiftUI
import Foundation
import QuartzCore
import AVFoundation
import GameController

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
    @Published var videoFrame: CGImage?
    @Published var canInitialize = true
    @Published var canLoadGame = false
    @Published var canRun = false
    
    private var frontend: LibretroFrontend?
    private let fileManager = FileManager.default
    private var displayLink: CADisplayLink?
    private var audioEngine: AVAudioEngine?
    private var audioPlayerNode: AVAudioPlayerNode?
    private var audioFormat: AVAudioFormat?
    private var gamepads: [GCController] = []
    
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
            
            setupAudio()
            
            setupGamepadHandling()
            
            isInitialized = true
            canInitialize = false
            canLoadGame = true
            errorMessage = nil
            log("Emulator initialized successfully")
        } catch {
            log("Error initializing emulator: \(error)")
            errorMessage = error.localizedDescription
        }
    }
    
    private func setupAudio() {
        audioEngine = AVAudioEngine()
        audioPlayerNode = AVAudioPlayerNode()
        
        guard let audioEngine = audioEngine,
              let audioPlayerNode = audioPlayerNode else {
            log("Failed to create audio engine or player node")
            return
        }
        
        audioFormat = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)
        
        audioEngine.attach(audioPlayerNode)
        audioEngine.connect(audioPlayerNode, to: audioEngine.mainMixerNode, format: audioFormat)
        
        do {
            try audioEngine.start()
            log("Audio engine started successfully")
        } catch {
            log("Failed to start audio engine: \(error)")
        }
    }
    
    private func setupGamepadHandling() {
        NotificationCenter.default.addObserver(self, selector: #selector(handleControllerConnected), name: .GCControllerDidConnect, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleControllerDisconnected), name: .GCControllerDidDisconnect, object: nil)
        
        gamepads = GCController.controllers()
        for gamepad in gamepads {
            configureGamepadHandlers(gamepad)
        }
    }
    
    @objc private func handleControllerConnected(_ notification: Notification) {
        guard let gamepad = notification.object as? GCController else { return }
        gamepads.append(gamepad)
        configureGamepadHandlers(gamepad)
    }
    
    @objc private func handleControllerDisconnected(_ notification: Notification) {
        guard let gamepad = notification.object as? GCController else { return }
        gamepads.removeAll { $0 == gamepad }
    }
    
    private func configureGamepadHandlers(_ gamepad: GCController) {
        gamepad.extendedGamepad?.valueChangedHandler = { [weak self] (gamepad, element) in
            self?.handleGamepadInput(gamepad: gamepad)
        }
    }
    
    private func handleGamepadInput(gamepad: GCExtendedGamepad) {
        let buttonMappings: [(GCControllerButtonInput, UInt32)] = [
            (gamepad.buttonA, RETRO_DEVICE_ID_JOYPAD.A),
            (gamepad.buttonB, RETRO_DEVICE_ID_JOYPAD.B),
            (gamepad.buttonX, RETRO_DEVICE_ID_JOYPAD.X),
            (gamepad.buttonY, RETRO_DEVICE_ID_JOYPAD.Y),
            (gamepad.leftShoulder, RETRO_DEVICE_ID_JOYPAD.L),
            (gamepad.rightShoulder, RETRO_DEVICE_ID_JOYPAD.R),
            (gamepad.leftTrigger, RETRO_DEVICE_ID_JOYPAD.L2),
            (gamepad.rightTrigger, RETRO_DEVICE_ID_JOYPAD.R2),
            (gamepad.dpad.up, RETRO_DEVICE_ID_JOYPAD.UP),
            (gamepad.dpad.down, RETRO_DEVICE_ID_JOYPAD.DOWN),
            (gamepad.dpad.left, RETRO_DEVICE_ID_JOYPAD.LEFT),
            (gamepad.dpad.right, RETRO_DEVICE_ID_JOYPAD.RIGHT)
        ]
        
        for (button, retroButton) in buttonMappings {
            frontend?.updateInputState(port: 0, buttonId: retroButton, isPressed: button.isPressed)
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
            canLoadGame = false
            canRun = true
            errorMessage = nil
            log("Game loaded successfully")
        } else {
            isGameLoaded = false
            errorMessage = EmulatorError.gameLoadFailed.localizedDescription
            log("Failed to load game")
        }
    }
    
    func runCore() {
        guard let frontend = frontend, isGameLoaded else {
            errorMessage = "Game not loaded or emulator not initialized"
            return
        }
        
        log("Starting core execution...")
        isRunning = true
        
        frontend.setVideoOutputHandler { [weak self] buffer, width, height, pitch in
            if let cgImage = self?.createCGImage(from: buffer, width: width, height: height, pitch: pitch) {
                DispatchQueue.main.async {
                    self?.videoFrame = cgImage
                }
            }
        }
        
        frontend.setAudioOutputHandler { [weak self] buffer, frames in
            self?.processAudio(buffer, frames: frames)
        }
        
        displayLink = CADisplayLink(target: self, selector: #selector(step))
        displayLink?.add(to: .main, forMode: .common)
    }
    
    @objc private func step(displayLink: CADisplayLink) {
        frontend?.runCore()
    }
    
    func stopEmulator() {
        log("Stopping emulator...")
        displayLink?.invalidate()
        displayLink = nil
        frontend = nil
        isRunning = false
        isGameLoaded = false
        isInitialized = false
        canInitialize = true
        canLoadGame = false
        canRun = false
        
        audioEngine?.stop()
        audioPlayerNode?.stop()
        audioEngine = nil
        audioPlayerNode = nil
        audioFormat = nil
        
        log("Emulator stopped")
    }
    
    private func log(_ message: String) {
        print(message)
        DispatchQueue.main.async {
            self.logMessages.append(message)
        }
    }
    
    private func createCGImage(from buffer: UnsafeRawPointer, width: Int, height: Int, pitch: Int) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let context = CGContext(data: UnsafeMutableRawPointer(mutating: buffer),
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: pitch,
                                      space: colorSpace,
                                      bitmapInfo: bitmapInfo.rawValue) else {
            return nil
        }
        return context.makeImage()
    }
    
    private func processAudio(_ buffer: UnsafePointer<Int16>, frames: Int) {
        guard let audioFormat = audioFormat else {
            log("Audio format not set")
            return
        }
        
        let audioBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: UInt32(frames))
        audioBuffer?.frameLength = UInt32(frames)
        
        let channels = UInt32(audioFormat.channelCount)
        
        for channel in 0..<channels {
            let channelData = audioBuffer?.floatChannelData?[Int(channel)]
            let stride = Int(channels)
            
            for frame in 0..<frames {
                let sampleOffset = frame * stride + Int(channel)
                let sample = Float(buffer[sampleOffset]) / Float(Int16.max)
                channelData?[frame] = sample
            }
        }
        
        audioPlayerNode?.scheduleBuffer(audioBuffer!)
        audioPlayerNode?.play()
    }
}

struct ContentView: View {
    @StateObject private var emulatorManager = EmulatorManager()
    
    var body: some View {
        ZStack {
            if let videoFrame = emulatorManager.videoFrame {
                Image(uiImage: UIImage(cgImage: videoFrame))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .edgesIgnoringSafeArea(.all)
            } else {
                Color.black.edgesIgnoringSafeArea(.all)
            }
            
            VStack {
                Spacer()
                
                HStack {
                    Button(action: {
                        emulatorManager.initializeEmulator()
                    }) {
                        Text("Initialize")
                            .padding()
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }
                    .disabled(!emulatorManager.canInitialize)
                    
                    Button(action: {
                        emulatorManager.loadGame()
                    }) {
                        Text("Load Game")
                            .padding()
                            .background(Color.green)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }
                    .disabled(!emulatorManager.canLoadGame)
                    
                    Button(action: {
                        if emulatorManager.isRunning {
                            emulatorManager.stopEmulator()
                        } else {
                            emulatorManager.runCore()
                        }
                    }) {
                        Text(emulatorManager.isRunning ? "Stop" : "Run")
                            .padding()
                            .background(emulatorManager.isRunning ? Color.red : Color.orange)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }
                    .disabled(!emulatorManager.canRun)
                }
                .padding(.bottom, 20)
            }
            
            if let errorMessage = emulatorManager.errorMessage {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .padding()
            }
        }
    }
}

#if DEBUG
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
#endif