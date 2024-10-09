import Foundation
import Metal
import UIKit

// Global variable to hold the LibretroFrontend instance
var globalFrontend: LibretroFrontend?

// Global callback functions
let videoRefreshCallback: @convention(c) (UnsafeRawPointer?, UInt32, UInt32, Int) -> Void = { data, width, height, pitch in
    globalFrontend?.handleVideoRefresh(data: data, width: width, height: height, pitch: pitch)
}

let audioSampleCallback: @convention(c) (Int16, Int16) -> Void = { left, right in
    globalFrontend?.handleAudioSample(left: left, right: right)
}

let inputPollCallback: @convention(c) () -> Void = {
    globalFrontend?.pollInput()
}

let inputStateCallback: @convention(c) (UInt32, UInt32, UInt32, UInt32) -> Int16 = { port, device, index, id in
    return globalFrontend?.getInputState(port: port, device: device, index: index, id: id) ?? 0
}

enum LibretroError: Error {
    case failedToLoadCore(String)
    case failedToLoadSymbol(String)
    case failedToLoadGame
    case failedToInitialize(String)
}

class LibretroFrontend {
    private var isRunning = false
    private var displayLink: CADisplayLink?
    private var metalDevice: MTLDevice?
    private var metalCommandQueue: MTLCommandQueue?
    private var metalTexture: MTLTexture?
    private var coreHandle: UnsafeMutableRawPointer?

    // Configuration
    var audioSampleRate: Double = 44100
    var assetsDirectory: String?

    init() {
        setupMetal()
        setAssetsDirectoryToDocuments()
    }

    deinit {
        stopEmulator()
    }

    private func setupMetal() {
        metalDevice = MTLCreateSystemDefaultDevice()
        metalCommandQueue = metalDevice?.makeCommandQueue()
    }

    func setAssetsDirectoryToDocuments() {
        let paths = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)
        print("Searching for documents directory at \(paths)")
        if let documentsDir = paths.first {
            print("Found documents directory at \(documentsDir)")
            self.assetsDirectory = documentsDir + "/PPSSPP"
            print("Calling prepareAssetsDirectory()")
            prepareAssetsDirectory()
        }
    }

    private func prepareAssetsDirectory() {
        guard let assetsDir = assetsDirectory else {
            print("[ASSETS] Assets directory is not set")
            return
        }
        
        let fileManager = FileManager.default
        let bundlePath = Bundle.main.resourcePath!
        let ppssppAssetsPath = "\(bundlePath)/PPSSPP"
        
        print("[ASSETS] PPSSPP assets source directory: \(ppssppAssetsPath)")
        
        if !fileManager.fileExists(atPath: assetsDir) {
            print("[ASSETS] Creating assetsDir directory at \(assetsDir)")
            do {
                try fileManager.createDirectory(atPath: assetsDir, withIntermediateDirectories: true, attributes: nil)
                print("[ASSETS] Successfully created assetsDir directory")
            } catch {
                print("[ASSETS] Failed to create assetsDir directory: \(error)")
                return
            }
        }
        
        // Check if PPSSPP assets exist in the bundle
        if fileManager.fileExists(atPath: ppssppAssetsPath) {
            print("[ASSETS] PPSSPP assets found in bundle, copying to Documents directory")
            do {
                try copyDirectory(from: ppssppAssetsPath, to: "\(assetsDir)/PPSSPP")
                print("[ASSETS] Copied PPSSPP assets to Documents directory")
            } catch {
                print("[ASSETS] Failed to copy PPSSPP assets: \(error)")
            }
        } else {
            print("[ASSETS] PPSSPP assets not found in bundle, creating necessary directories")
            let directories = ["PPSSPP", "PPSSPP/system", "PPSSPP/saves", "PPSSPP/cores"]
            for directory in directories {
                let fullPath = "\(assetsDir)/\(directory)"
                if !fileManager.fileExists(atPath: fullPath) {
                    do {
                        try fileManager.createDirectory(atPath: fullPath, withIntermediateDirectories: true, attributes: nil)
                        print("[ASSETS] Created directory: \(fullPath)")
                    } catch {
                        print("[ASSETS] Failed to create directory \(fullPath): \(error)")
                    }
                }
            }
        }
    }

    private func copyDirectory(from sourcePath: String, to destinationPath: String) throws {
        let fileManager = FileManager.default
        let sourceURL = URL(fileURLWithPath: sourcePath)
        let destinationURL = URL(fileURLWithPath: destinationPath)
        
        if !fileManager.fileExists(atPath: sourcePath) {
            print("[COPY] Source path does not exist: \(sourcePath)")
            return
        }
        
        try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true, attributes: nil)
        
        let enumerator = fileManager.enumerator(at: sourceURL, includingPropertiesForKeys: [.isDirectoryKey], options: [])
        while let sourceURL = enumerator?.nextObject() as? URL {
            let destinationURL = destinationURL.appendingPathComponent(sourceURL.lastPathComponent)
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
        }
    }

    private func isDirectory(atPath path: String?) -> Bool {
        print("Checking if path is a directory: \(path ?? "nil")")
        
        guard let path = path else {
            print("Invalid (nil) path provided to isDirectory")
            return false
        }
        
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        
        if !exists {
            print("Path does not exist: \(path)")
        }
        
        return exists && isDir.boolValue
    }

    func startEmulator(corePath: String, romPath: String) throws {
        print("[START] Starting emulator with core: \(corePath) and ROM: \(romPath)")
        
        globalFrontend = self

        // Load the Libretro core
        print("[START] Attempting to load core from: \(corePath)")
        guard let coreHandle = dlopen(corePath, RTLD_LAZY) else {
            let error = String(cString: dlerror())
            print("[START] Failed to load core: \(error)")
            throw LibretroError.failedToLoadCore(error)
        }
        self.coreHandle = coreHandle
        print("[START] Core loaded successfully")

        // Set up environment callback
        print("[START] Setting up environment callback")
        guard let retro_set_environment_ptr = dlsym(coreHandle, "retro_set_environment") else {
            print("[START] Failed to load retro_set_environment")
            throw LibretroError.failedToLoadSymbol("retro_set_environment")
        }
        let retro_set_environment = unsafeBitCast(retro_set_environment_ptr, to: (@convention(c) (@escaping @convention(c) (UInt32, UnsafeMutableRawPointer?) -> Bool) -> Void).self)
        retro_set_environment(envCallback)
        print("[START] Environment callback set up")

        // Initialize the core
        print("Attempting to initialize core")
        guard let retro_init_ptr = dlsym(coreHandle, "retro_init") else {
            print("[START] Failed to load retro_init")
            throw LibretroError.failedToLoadSymbol("retro_init")
        }
        let retro_init = unsafeBitCast(retro_init_ptr, to: (@convention(c) () -> Void).self)
        print("[START] About to call retro_init")
        retro_init()
        print("[START] retro_init called successfully")

        // Set up callbacks
        setupCallbacks()

        // Load the game
        let cString = romPath.utf8CString
        var gameInfo = retro_game_info(path: cString.withUnsafeBufferPointer { $0.baseAddress }, data: nil, size: 0, meta: nil)

        guard let retro_load_game_ptr = dlsym(coreHandle, "retro_load_game") else {
            print("[START] Failed to load retro_load_game")
            throw LibretroError.failedToLoadSymbol("retro_load_game")
        }
        let retro_load_game = unsafeBitCast(retro_load_game_ptr, to: (@convention(c) (UnsafePointer<retro_game_info>?) -> Bool).self)

        print("[START] Attempting to load game")
        if retro_load_game(&gameInfo) {
            print("[START] Game loaded successfully")
            startGameLoop()
        } else {
            print("[START] Failed to load game")
            throw LibretroError.failedToLoadGame
        }
    }

    private func setupCallbacks() {
        print("[CALLBACKS] Setting up callbacks")
        globalFrontend = self
        guard let coreHandle = coreHandle else {
            print("[CALLBACKS] Core handle is nil, cannot set up callbacks")
            return
        }

        if let retro_set_video_refresh = dlsym(coreHandle, "retro_set_video_refresh").map({ unsafeBitCast($0, to: (@convention(c) (@convention(c) (UnsafeRawPointer?, UInt32, UInt32, Int) -> Void) -> Void).self) }) {
            retro_set_video_refresh(videoRefreshCallback)
            print("[CALLBACKS] Video refresh callback set")
        } else {
            print("[CALLBACKS] Failed to set video refresh callback")
        }

        if let retro_set_audio_sample = dlsym(coreHandle, "retro_set_audio_sample").map({ unsafeBitCast($0, to: (@convention(c) (@convention(c) (Int16, Int16) -> Void) -> Void).self) }) {
            retro_set_audio_sample(audioSampleCallback)
            print("[CALLBACKS] Audio sample callback set")
        } else {
            print("[CALLBACKS] Failed to set audio sample callback")
        }

        if let retro_set_input_poll = dlsym(coreHandle, "retro_set_input_poll").map({ unsafeBitCast($0, to: (@convention(c) (@convention(c) () -> Void) -> Void).self) }) {
            retro_set_input_poll(inputPollCallback)
            print("[CALLBACKS] Input poll callback set")
        } else {
            print("[CALLBACKS] Failed to set input poll callback")
        }

        if let retro_set_input_state = dlsym(coreHandle, "retro_set_input_state").map({ unsafeBitCast($0, to: (@convention(c) (@convention(c) (UInt32, UInt32, UInt32, UInt32) -> Int16) -> Void).self) }) {
            retro_set_input_state(inputStateCallback)
            print("[CALLBACKS] Input state callback set")
        } else {
            print("[CALLBACKS] Failed to set input state callback")
        }
    }

    private func startGameLoop() {
        print("[STARTLOOP] Starting game loop")
        isRunning = true
        displayLink = CADisplayLink(target: self, selector: #selector(gameLoop))
        displayLink?.add(to: .main, forMode: .common)
    }

    @objc private func gameLoop() {
        guard isRunning, let coreHandle = coreHandle else {
            print("[LOOP] Game loop called but isRunning is false or coreHandle is nil")
            return
        }
        if let retro_run = dlsym(coreHandle, "retro_run").map({ unsafeBitCast($0, to: (@convention(c) () -> Void).self) }) {
            retro_run()
        } else {
            print("[LOOP] Failed to find retro_run symbol")
        }
    }

    func handleVideoRefresh(data: UnsafeRawPointer?, width: UInt32, height: UInt32, pitch: Int) {
        guard let data = data else {
            print("[VIDEO] Received null data in video refresh")
            return
        }

        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: Int(width),
            height: Int(height),
            mipmapped: false
        )
        metalTexture = metalDevice?.makeTexture(descriptor: textureDescriptor)

        let region = MTLRegionMake2D(0, 0, Int(width), Int(height))
        metalTexture?.replace(region: region, mipmapLevel: 0, withBytes: data, bytesPerRow: pitch)

        print("[VIDEO] Received video frame: \(width)x\(height)")
        // Here you would render the texture to the screen using Metal
    }

    func handleAudioSample(left: Int16, right: Int16) {
        // Handle audio sample
        print("[AUDIO] Received audio sample: L=\(left), R=\(right)")
    }

    func pollInput() {
        // Poll input devices
        print("[POLLINPUT] Input polled")
    }

    func getInputState(port: UInt32, device: UInt32, index: UInt32, id: UInt32) -> Int16 {
        // Return input state
        print("[INPUTSTATE] Input state requested: port=\(port), device=\(device), index=\(index), id=\(id)")
        return 0
    }

    func stopEmulator() {
        print("[STOP] Stopping emulator")
        isRunning = false
        displayLink?.invalidate()
        displayLink = nil

        if let coreHandle = coreHandle {
            if let retro_unload_game = dlsym(coreHandle, "retro_unload_game").map({ unsafeBitCast($0, to: (@convention(c) () -> Void).self) }) {
                retro_unload_game()
                print("[STOP] Game unloaded")
            } else {
                print("[STOP] Failed to unload game")
            }
            if let retro_deinit = dlsym(coreHandle, "retro_deinit").map({ unsafeBitCast($0, to: (@convention(c) () -> Void).self) }) {
                retro_deinit()
                print("[STOP] Core deinitialized")
            } else {
                print("[STOP] Failed to deinitialize core")
            }
            dlclose(coreHandle)
            print("[STOP] Core handle closed")
        }
        coreHandle = nil
        globalFrontend = nil
        print("[STOP] Emulator stopped")
    }
}

let envCallback: @convention(c) (UInt32, UnsafeMutableRawPointer?) -> Bool = { cmd, data in
    guard let frontend = globalFrontend else {
        print("[ENV] Environment callback called but globalFrontend is nil")
        return false
    }
    
    print("[ENV] Received environment callback: \(cmd)")
    
    switch cmd {
    case 31: // RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY
        print("[ENV] RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY called")
        if let data = data?.assumingMemoryBound(to: UnsafeMutablePointer<Int8>?.self) {
            if let assetsDir = frontend.assetsDirectory {
                let saveDir = "\(assetsDir)/saves"
                let fileManager = FileManager.default
                print("[ENV] Checking if save directory exists: \(saveDir)")
                if !fileManager.fileExists(atPath: saveDir) {
                    print("[ENV] Save directory does not exist, attempting to create it")
                    do {
                        try fileManager.createDirectory(atPath: saveDir, withIntermediateDirectories: true, attributes: nil)
                        print("[ENV] Successfully created save directory")
                    } catch {
                        print("[ENV] Failed to create save directory: \(error)")
                        return false
                    }
                } else {
                    print("[ENV] Save directory already exists")
                }
                data.pointee = strdup(saveDir)
                print("[ENV] Save directory set to: \(saveDir)")
                return true
            } else {
                print("[ENV] Assets directory is nil, cannot set save directory")
            }
        } else {
            print("[ENV] Invalid data pointer for save directory")
        }
        return false

    case 9: // RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY
        print("[ENV] RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY called")
        if let data = data?.assumingMemoryBound(to: UnsafeMutablePointer<Int8>?.self) {
            if let assetsDir = frontend.assetsDirectory {
                let systemDir = "\(assetsDir)/system"
                let fileManager = FileManager.default
                print("[ENV] Checking if system directory exists: \(systemDir)")
                if !fileManager.fileExists(atPath: systemDir) {
                    print("[ENV] System directory does not exist, attempting to create it")
                    do {
                        try fileManager.createDirectory(atPath: systemDir, withIntermediateDirectories: true, attributes: nil)
                        print("[ENV] Successfully created system directory")
                    } catch {
                        print("[ENV] Failed to create system directory: \(error)")
                        return false
                    }
                } else {
                    print("[ENV] System directory already exists")
                }
                data.pointee = strdup(systemDir)
                print("[ENV] System directory set to: \(systemDir)")
                return true
            } else {
                print("[ENV] Assets directory is nil, cannot set system directory")
            }
        } else {
            print("[ENV] Invalid data pointer for system directory")
        }
        return false

    case 30: // RETRO_ENVIRONMENT_GET_CORE_ASSETS_DIRECTORY
        print("[ENV] RETRO_ENVIRONMENT_GET_CORE_ASSETS_DIRECTORY called")
        if let data = data?.assumingMemoryBound(to: UnsafeMutablePointer<Int8>?.self) {
            if let assetsDir = frontend.assetsDirectory {
                let coreAssetsDir = "\(assetsDir)/cores"
                let fileManager = FileManager.default
                print("[ENV] Checking if core assets directory exists: \(coreAssetsDir)")
                if !fileManager.fileExists(atPath: coreAssetsDir) {
                    print("[ENV] Core assets directory does not exist, attempting to create it")
                    do {
                        try fileManager.createDirectory(atPath: coreAssetsDir, withIntermediateDirectories: true, attributes: nil)
                        print("[ENV] Successfully created core assets directory")
                    } catch {
                        print("[ENV] Failed to create core assets directory: \(error)")
                        return false
                    }
                } else {
                    print("[ENV] Core assets directory already exists")
                }
                data.pointee = strdup(coreAssetsDir)
                print("[ENV] Core assets directory set to: \(coreAssetsDir)")
                return true
            } else {
                print("[ENV] Assets directory is nil, cannot set core assets directory")
            }
        } else {
            print("[ENV] Invalid data pointer for core assets directory")
        }
        return false

    // Add more cases for other commands as needed

    default:
        print("[ENV] Unhandled environment command: \(cmd)")
    }
    return false
}
