import Foundation
import AVFoundation
import CoreGraphics
import GameController

// Global variable to hold our LibretroFrontend instance
var globalLibretroFrontend: LibretroFrontend?

@_cdecl("swiftEnvironCallback")
public func swiftEnvironCallback(cmd: UInt32, data: UnsafeMutableRawPointer?) -> Bool {
    return globalLibretroFrontend?.environCallback(cmd, data) ?? false
}

enum LibretroError: Error {
    case failedToLoadCore(String)
    case symbolNotFound(String)
    case initializationFailed
    case gameLoadFailed
}

class LibretroFrontend: ObservableObject {
    @Published var isInitialized = false
    @Published var isRunning = false
    @Published var errorMessage: String?
    @Published var isGameLoaded = false
    @Published var logMessages: [String] = []
    @Published var videoFrame: CGImage?
    @Published var canInitialize = true
    @Published var canLoadGame = false
    @Published var canRun = false

    private let dylibPath: String
    private let isoPath: String
    private var coreHandle: UnsafeMutableRawPointer?
    private var audioEngine: AVAudioEngine?
    private var audioPlayerNode: AVAudioPlayerNode?
    private var audioFormat: AVAudioFormat?
    private var gamepads: [GCController] = []
    private var displayLink: CADisplayLink?

    private var retro_run: (() -> Void)?
    private var retro_get_system_av_info: ((UnsafeMutableRawPointer) -> Void)?
    private var retro_load_game: ((UnsafeRawPointer) -> Bool)?
    private var retro_init: (() -> Void)?
    private var retro_deinit: (() -> Void)?

    private var currentPixelFormat: retro_pixel_format = .RETRO_PIXEL_FORMAT_0RGB1555
    private var inputState: [UInt32: [UInt32: Bool]] = [:]

    init(dylibPath: String, isoPath: String) {
        self.dylibPath = dylibPath
        self.isoPath = isoPath
        globalLibretroFrontend = self
        setupDirectories()
        setupAudio()
        setupGamepadHandling()
    }

    deinit {
        stopEmulation()
        globalLibretroFrontend = nil
    }

    func initializeEmulator() {
        log("Initializing emulator...")
        do {
            try setupCore()
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

    func loadGame() {
        guard isInitialized else {
            errorMessage = "Emulator not initialized"
            return
        }

        log("Attempting to load game from path: \(isoPath)")
        if loadGame(at: isoPath) {
            isGameLoaded = true
            canLoadGame = false
            canRun = true
            errorMessage = nil
            log("Game loaded successfully")
        } else {
            isGameLoaded = false
            errorMessage = "Failed to load game"
            log("Failed to load game")
        }
    }

    func runCore() {
        guard isGameLoaded else {
            errorMessage = "Game not loaded or emulator not initialized"
            return
        }

        log("Starting core execution...")
        isRunning = true

        displayLink = CADisplayLink(target: self, selector: #selector(step))
        displayLink?.add(to: .main, forMode: .common)
    }

    func stopEmulation() {
        log("Stopping emulator...")
        displayLink?.invalidate()
        displayLink = nil
        retro_deinit?()
        dlclose(coreHandle)
        coreHandle = nil
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

    // MARK: - Private Methods
    
    private func setupDirectories() {
        let fileManager = FileManager.default
        let documentsPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first!
        
        let systemDir = (documentsPath as NSString).appendingPathComponent("system")
        let savesDir = (documentsPath as NSString).appendingPathComponent("saves")
        let assetsDir = (systemDir as NSString).appendingPathComponent("PPSSPP")
        
        try? fileManager.createDirectory(atPath: systemDir, withIntermediateDirectories: true, attributes: nil)
        try? fileManager.createDirectory(atPath: savesDir, withIntermediateDirectories: true, attributes: nil)
        try? fileManager.createDirectory(atPath: assetsDir, withIntermediateDirectories: true, attributes: nil)
        
        log("System directory: \(systemDir)")
        log("Saves directory: \(savesDir)")
        log("Assets directory: \(assetsDir)")
    }
    
    private func setupAudio() {
        audioEngine = AVAudioEngine()
        log("Audio engine initialized")
        // Further audio setup would go here
    }
    
    private func setupCore() throws {
        log("Setting up core from path: \(dylibPath)")
        guard let handle = dlopen(dylibPath, RTLD_LAZY) else {
            throw LibretroError.failedToLoadCore(String(cString: dlerror()))
        }
        coreHandle = handle

        guard let retro_set_environment = dlsym(handle, "retro_set_environment").map({ unsafeBitCast($0, to: (@convention(c) (@convention(c) (UInt32, UnsafeMutableRawPointer?) -> Bool) -> Void).self) }),
              let retro_init = dlsym(handle, "retro_init").map({ unsafeBitCast($0, to: (@convention(c) () -> Void).self) }),
              let retro_deinit = dlsym(handle, "retro_deinit").map({ unsafeBitCast($0, to: (@convention(c) () -> Void).self) }),
              let retro_run = dlsym(handle, "retro_run").map({ unsafeBitCast($0, to: (@convention(c) () -> Void).self) }),
              let retro_get_system_av_info = dlsym(handle, "retro_get_system_av_info").map({ unsafeBitCast($0, to: (@convention(c) (UnsafeMutableRawPointer) -> Void).self) }),
              let retro_set_video_refresh = dlsym(handle, "retro_set_video_refresh").map({ unsafeBitCast($0, to: (@convention(c) (@convention(c) (UnsafeRawPointer?, UInt32, UInt32, Int) -> Void) -> Void).self) }),
              let retro_set_audio_sample = dlsym(handle, "retro_set_audio_sample").map({ unsafeBitCast($0, to: (@convention(c) (@convention(c) (Int16, Int16) -> Void) -> Void).self) }),
              let retro_set_audio_sample_batch = dlsym(handle, "retro_set_audio_sample_batch").map({ unsafeBitCast($0, to: (@convention(c) (@convention(c) (UnsafePointer<Int16>?, Int) -> Int) -> Void).self) }),
              let retro_set_input_poll = dlsym(handle, "retro_set_input_poll").map({ unsafeBitCast($0, to: (@convention(c) (@convention(c) () -> Void) -> Void).self) }),
              let retro_set_input_state = dlsym(handle, "retro_set_input_state").map({ unsafeBitCast($0, to: (@convention(c) (@convention(c) (UInt32, UInt32, UInt32, UInt32) -> Int16) -> Void).self) }),
              let retro_load_game = dlsym(handle, "retro_load_game").map({ unsafeBitCast($0, to: (@convention(c) (UnsafeRawPointer) -> Bool).self) })
        else {
            throw LibretroError.symbolNotFound("Core function")
        }

        retro_set_environment(swiftEnvironCallback)
        retro_set_video_refresh(videoRefreshCallback)
        retro_set_audio_sample(audioSampleCallback)
        retro_set_audio_sample_batch(audioSampleBatchCallback)
        retro_set_input_poll(inputPollCallback)
        retro_set_input_state(inputStateCallback)

        self.retro_init = retro_init
        self.retro_deinit = retro_deinit
        self.retro_run = retro_run
        self.retro_get_system_av_info = retro_get_system_av_info
        self.retro_load_game = retro_load_game

        retro_init()
        log("Core set up and initialized")
    }
    
    private func loadGame(at path: String) -> Bool {
        log("Loading game from path: \(path)")
        guard let retro_load_game = self.retro_load_game else {
            log("Core functions not set up properly")
            return false
        }

        var gameInfo = retro_game_info(
            path: (path as NSString).utf8String,
            data: nil,
            size: 0,
            meta: nil
        )

        return retro_load_game(&gameInfo)
    }
    
    @objc private func step(displayLink: CADisplayLink) {
        retro_run?()
    }
    
    // MARK: - Callback Methods
    
    func environCallback(_ cmd: UInt32, _ data: UnsafeMutableRawPointer?) -> Bool {
        switch cmd {
        case RETRO_ENVIRONMENT_GET_LOG_INTERFACE.rawValue:
            if let data = data?.assumingMemoryBound(to: retro_log_callback.self) {
                data.pointee.log = { (level: UInt32, fmt: UnsafePointer<CChar>?, args: OpaquePointer) in
                    guard let fmt = fmt else { return }
                    let levelString = ["DEBUG", "INFO", "WARN", "ERROR"][Int(level)]
                    print("Libretro [\(levelString)]")
                }
                return true
            }
        
        case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY.rawValue:
            if let data = data?.assumingMemoryBound(to: UnsafePointer<CChar>?.self) {
                let systemDir = (NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first! as NSString).appendingPathComponent("system")
                data.pointee = (systemDir as NSString).utf8String
                return true
            }
        
        case RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY.rawValue:
            if let data = data?.assumingMemoryBound(to: UnsafePointer<CChar>?.self) {
                let savesDir = (NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first! as NSString).appendingPathComponent("saves")
                data.pointee = (savesDir as NSString).utf8String
                return true
            }
        
        case RETRO_ENVIRONMENT_GET_LANGUAGE.rawValue:
            if let data = data?.assumingMemoryBound(to: UInt32.self) {
                data.pointee = RETRO_LANGUAGE_ENGLISH.rawValue
                return true
            }
        
        case RETRO_ENVIRONMENT_GET_VARIABLE.rawValue:
            if let data = data?.assumingMemoryBound(to: retro_variable.self) {
                if let key = data.pointee.key {
                    let variableName = String(cString: key)
                    print("Core requesting variable: \(variableName)")
                    
                    let defaultValue = "default_value"
                    data.pointee.value = UnsafePointer(strdup(defaultValue))
                    
                    return true
                } else {
                    print("Core requested variable with null key")
                    return false
                }
            }
        
        case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT.rawValue:
            if let data = data?.assumingMemoryBound(to: retro_pixel_format.self) {
                let format = data.pointee
                if format == .RETRO_PIXEL_FORMAT_XRGB8888 {
                    self.currentPixelFormat = format
                    print("Pixel format set to XRGB8888")
                    return true
                } else {
                    print("Unsupported pixel format requested: \(format)")
                    return false
                }
            }
        
        default:
            print("Unhandled environment call: \(cmd)")
            return false
        }
        
        return false
    }
    
    private let videoRefreshCallback: @convention(c) (UnsafeRawPointer?, UInt32, UInt32, Int) -> Void = { (data, width, height, pitch) in
        guard let data = data else { return }
        globalLibretroFrontend?.handleVideoFrame(data, width: Int(width), height: Int(height), pitch: Int(pitch))
    }
    
    private func handleVideoFrame(_ videoData: UnsafeRawPointer, width: Int, height: Int, pitch: Int) {
        guard let cgImage = createCGImage(from: videoData, width: width, height: height, pitch: pitch) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.videoFrame = cgImage
        }
    }
    
    private let audioSampleCallback: @convention(c) (Int16, Int16) -> Void = { (left, right) in
        // Handle audio sample if needed
    }
    
    private let audioSampleBatchCallback: @convention(c) (UnsafePointer<Int16>?, Int) -> Int = { (data, frames) in
        // Handle audio batch if needed
        return frames
    }
    
    private let inputPollCallback: @convention(c) () -> Void = {
        // Handle input polling if needed
    }
    
    private let inputStateCallback: @convention(c) (UInt32, UInt32, UInt32, UInt32) -> Int16 = { (port, device, index, id) in
        return globalLibretroFrontend?.handleInputState(port: port, device: device, index: index, id: id) ?? 0
    }
    
    private func handleInputState(port: UInt32, device: UInt32, index: UInt32, id: UInt32) -> Int16 {
        return inputState[port]?[id] == true ? 1 : 0
    }
    
    // MARK: - Utility Methods
    
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
            updateInputState(port: 0, buttonId: retroButton, isPressed: button.isPressed)
        }
    }

    private func updateInputState(port: UInt32, buttonId: UInt32, isPressed: Bool) {
        if inputState[port] == nil {
            inputState[port] = [:]
        }
        inputState[port]?[buttonId] = isPressed
    }
}

// Libretro types and constants
struct RETRO_ENVIRONMENT_GET_LOG_INTERFACE { static let rawValue: UInt32 = 27 }
struct RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY { static let rawValue: UInt32 = 9 }
struct RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY { static let rawValue: UInt32 = 31 }
struct RETRO_ENVIRONMENT_GET_LANGUAGE { static let rawValue: UInt32 = 39 }
struct RETRO_ENVIRONMENT_SET_LOGGING_INTERFACE { static let rawValue: UInt32 = 70 }
struct RETRO_LANGUAGE_ENGLISH { static let rawValue: UInt32 = 0 }
struct RETRO_ENVIRONMENT_GET_VARIABLE { static let rawValue: UInt32 = 15 }
struct RETRO_ENVIRONMENT_SET_PIXEL_FORMAT { static let rawValue: UInt32 = 10 }

struct retro_log_callback {
    var log: (@convention(c) (UInt32, UnsafePointer<CChar>?, OpaquePointer) -> Void)?
}

struct retro_game_geometry {
    var base_width: UInt32
    var base_height: UInt32
    var max_width: UInt32
    var max_height: UInt32
    var aspect_ratio: Float
}

struct retro_system_timing {
    var fps: Double
    var sample_rate: Double
}

struct retro_system_av_info {
    var geometry: retro_game_geometry
    var timing: retro_system_timing
}

struct retro_variable {
    var key: UnsafePointer<CChar>?
    var value: UnsafePointer<CChar>?
}

struct retro_game_info {
    var path: UnsafePointer<CChar>?
    var data: UnsafeMutableRawPointer?
    var size: Int
    var meta: UnsafePointer<CChar>?
}

enum retro_pixel_format: UInt32 {
    case RETRO_PIXEL_FORMAT_0RGB1555 = 0
    case RETRO_PIXEL_FORMAT_XRGB8888 = 1
    case RETRO_PIXEL_FORMAT_RGB565 = 2
}

// Additional utility functions if needed

extension LibretroFrontend {
    // You can add extension methods here if you want to keep the main class definition cleaner
    
    // Add more utility methods as needed
}

// Add these constants for button mappings
struct RETRO_DEVICE_ID_JOYPAD {
    static let B: UInt32 = 0
    static let Y: UInt32 = 1
    static let SELECT: UInt32 = 2
    static let START: UInt32 = 3
    static let UP: UInt32 = 4
    static let DOWN: UInt32 = 5
    static let LEFT: UInt32 = 6
    static let RIGHT: UInt32 = 7
    static let A: UInt32 = 8
    static let X: UInt32 = 9
    static let L: UInt32 = 10
    static let R: UInt32 = 11
    static let L2: UInt32 = 12
    static let R2: UInt32 = 13
    static let L3: UInt32 = 14
    static let R3: UInt32 = 15
}

// Example usage:
// let libretro = LibretroFrontend(dylibPath: "/path/to/core.dylib", isoPath: "/path/to/game.iso")
// do {
//     try libretro.launch()
// } catch {
//     print("Error: \(error)")
// }