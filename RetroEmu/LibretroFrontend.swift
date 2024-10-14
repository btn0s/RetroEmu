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
}

enum retro_pixel_format: UInt32 {
    case RETRO_PIXEL_FORMAT_0RGB1555 = 0
    case RETRO_PIXEL_FORMAT_XRGB8888 = 1
    case RETRO_PIXEL_FORMAT_RGB565 = 2
}

class LibretroFrontend {
    private var coreHandle: UnsafeMutableRawPointer?
    private var audioEngine: AVAudioEngine?
    private var videoOutputHandler: ((UnsafeRawPointer, Int, Int, Int) -> Void)?
    private var currentWidth: Int = 0
    private var currentHeight: Int = 0
    private var currentPitch: Int = 0
    
    private var retro_run: (() -> Void)?
    private var retro_get_system_av_info: ((UnsafeMutableRawPointer) -> Void)?
    private var retro_load_game: ((UnsafeMutableRawPointer) -> Bool)?
    private var retro_init: (() -> Void)?
    
    private var currentPixelFormat: retro_pixel_format = .RETRO_PIXEL_FORMAT_0RGB1555
    
    private var debug = true
    
    private var lastVideoData: Data?
    private var lastCGImage: CGImage?
    
    private var audioOutputHandler: ((UnsafePointer<Int16>, Int) -> Void)?
    
    private var inputState: [UInt32: [UInt32: Bool]] = [:]
    
    // MARK: - Initialization
    
    init() {
        globalLibretroFrontend = self
        setupDirectories()
        setupAudio()
    }
    
    deinit {
        globalLibretroFrontend = nil
    }
    
    // MARK: - Directory Setup
    
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
    
    // MARK: - Audio Setup
    
    private func setupAudio() {
        audioEngine = AVAudioEngine()
        log("Audio engine initialized")
        // Further audio setup would go here
    }
    
    // MARK: - Libretro Environment Callbacks
    
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
    
    // MARK: - Video Output
    
    private let videoRefreshCallback: @convention(c) (UnsafeRawPointer?, UInt32, UInt32, Int) -> Void = { (data, width, height, pitch) in
        guard let data = data else {
            print("Received null video frame")
            return
        }
        
        globalLibretroFrontend?.handleVideoFrame(data, width: Int(width), height: Int(height), pitch: Int(pitch))
    }
    
    private func handleVideoFrame(_ videoData: UnsafeRawPointer, width: Int, height: Int, pitch: Int) {
        videoOutputHandler?(videoData, width, height, pitch)
    }
    
    // MARK: - Audio Output
    
    private let audioSampleCallback: @convention(c) (Int16, Int16) -> Void = { (left, right) in
        print("Received audio sample: L:\(left), R:\(right)")
    }
    
    private let audioSampleBatchCallback: @convention(c) (UnsafePointer<Int16>?, Int) -> Int = { (data, frames) in
        guard let data = data else {
            print("Received null audio batch")
            return 0
        }
        globalLibretroFrontend?.handleAudioSamples(data, frames: frames)
        return frames
    }
    
    // MARK: - Input Handling
    
    private let inputPollCallback: @convention(c) () -> Void = {
        print("Input poll called")
    }
    
    private let inputStateCallback: @convention(c) (UInt32, UInt32, UInt32, UInt32) -> Int16 = { (port, device, index, id) in
        return globalLibretroFrontend?.handleInputState(port: port, device: device, index: index, id: id) ?? 0
    }
    
    private func handleInputState(port: UInt32, device: UInt32, index: UInt32, id: UInt32) -> Int16 {
        return inputState[port]?[id] == true ? 1 : 0
    }
    
    func updateInputState(port: UInt32, buttonId: UInt32, isPressed: Bool) {
        if inputState[port] == nil {
            inputState[port] = [:]
        }
        inputState[port]?[buttonId] = isPressed
    }
    
    // MARK: - Core Loading and Running
    
    func setupCore(at path: String) throws {
        log("Setting up core from path: \(path)")
        // Load the core dylib
        guard let handle = dlopen(path, RTLD_LAZY) else {
            throw LibretroError.failedToLoadCore(String(cString: dlerror()))
        }
        coreHandle = handle

        // Set up function pointers
        guard let retro_set_environment = dlsym(handle, "retro_set_environment").map({ unsafeBitCast($0, to: (@convention(c) (@convention(c) (UInt32, UnsafeMutableRawPointer?) -> Bool) -> Void).self) }),
              let retro_init = dlsym(handle, "retro_init").map({ unsafeBitCast($0, to: (@convention(c) () -> Void).self) }),
              let retro_run = dlsym(handle, "retro_run").map({ unsafeBitCast($0, to: (@convention(c) () -> Void).self) }),
              let retro_get_system_av_info = dlsym(handle, "retro_get_system_av_info").map({ unsafeBitCast($0, to: (@convention(c) (UnsafeMutableRawPointer) -> Void).self) }),
              let retro_set_video_refresh = dlsym(handle, "retro_set_video_refresh").map({ unsafeBitCast($0, to: (@convention(c) (@convention(c) (UnsafeRawPointer?, UInt32, UInt32, Int) -> Void) -> Void).self) }),
              let retro_set_audio_sample = dlsym(handle, "retro_set_audio_sample").map({ unsafeBitCast($0, to: (@convention(c) (@convention(c) (Int16, Int16) -> Void) -> Void).self) }),
              let retro_set_audio_sample_batch = dlsym(handle, "retro_set_audio_sample_batch").map({ unsafeBitCast($0, to: (@convention(c) (@convention(c) (UnsafePointer<Int16>?, Int) -> Int) -> Void).self) }),
              let retro_set_input_poll = dlsym(handle, "retro_set_input_poll").map({ unsafeBitCast($0, to: (@convention(c) (@convention(c) () -> Void) -> Void).self) }),
              let retro_set_input_state = dlsym(handle, "retro_set_input_state").map({ unsafeBitCast($0, to: (@convention(c) (@convention(c) (UInt32, UInt32, UInt32, UInt32) -> Int16) -> Void).self) }),
              let retro_load_game = dlsym(handle, "retro_load_game").map({ unsafeBitCast($0, to: (@convention(c) (UnsafeMutableRawPointer) -> Bool).self) })
        else {
            throw LibretroError.symbolNotFound("Core function")
        }

        // Set environment
        retro_set_environment(swiftEnvironCallback)

        // Set other callbacks
        retro_set_video_refresh(videoRefreshCallback)
        retro_set_audio_sample(audioSampleCallback)
        retro_set_audio_sample_batch(audioSampleBatchCallback)
        retro_set_input_poll(inputPollCallback)
        retro_set_input_state(inputStateCallback)

        // Store function pointers
        self.retro_init = retro_init
        self.retro_run = retro_run
        self.retro_get_system_av_info = retro_get_system_av_info
        self.retro_load_game = retro_load_game

        // Initialize
        retro_init()

        log("Core set up and initialized from: \(path)")
    }
    
    func loadGame(at path: String) -> Bool {
        log("Loading game from path: \(path)")
        guard let retro_load_game = self.retro_load_game else {
            log("retro_load_game function not set up")
            return false
        }

        var gameInfo = retro_game_info(
            path: (path as NSString).utf8String,
            data: nil,
            size: 0,
            meta: nil
        )

        let success = retro_load_game(&gameInfo)
        log(success ? "Game loaded successfully" : "Failed to load game")
        return success
    }
    
    func runCore() {
        guard let retro_run = self.retro_run else {
            log("Core functions not set up properly")
            return
        }

        retro_run()
    }
    
    // MARK: - Utility
    
    private func log(_ message: String) {
        if debug {
            print("LibretroFrontend: \(message)")
        }
    }
    
    func setVideoOutputHandler(_ handler: @escaping (UnsafeRawPointer, Int, Int, Int) -> Void) {
        self.videoOutputHandler = handler
    }
    
    private func handleAudioSamples(_ samples: UnsafePointer<Int16>, frames: Int) {
        audioOutputHandler?(samples, frames)
    }
    
    func setAudioOutputHandler(_ handler: @escaping (UnsafePointer<Int16>, Int) -> Void) {
        self.audioOutputHandler = handler
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
// let libretro = LibretroFrontend()
// do {
//     try libretro.setupCore(at: "/path/to/core.dylib")
//     if libretro.loadGame(at: "/path/to/game.rom") {
//         libretro.runCore()
//     }
// } catch {
//     print("Error: \(error)")
// }