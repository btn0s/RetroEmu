import AVFoundation
import CoreGraphics
import Foundation
import GameController
import GLKit

// Global variable to hold our LibretroFrontend instance
var globalLibretroFrontend: LibretroFrontend?

@_cdecl("swiftEnvironCallback")
public func swiftEnvironCallback(cmd: Int32, data: UnsafeMutableRawPointer?) -> Bool {
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
    
    private let dylibPath: String
    private let isoPath: String
    private var coreHandle: UnsafeMutableRawPointer?
    private var displayLink: CADisplayLink?
    
    private var retro_run: (() -> Void)?
    private var retro_get_system_av_info: (@convention(c) (UnsafeMutableRawPointer) -> Void)?
    private var retro_load_game: (@convention(c) (UnsafeMutableRawPointer) -> Bool)?
    private var retro_init: (() -> Void)?
    private var retro_deinit: (() -> Void)?
    
    private var currentPixelFormat: retro_pixel_format = .RETRO_PIXEL_FORMAT_XRGB8888
    private var inputState: [UInt32: [UInt32: Bool]] = [:]
    
    private var glContext: EAGLContext?
    private var framebuffer: GLuint = 0
    private var renderbuffer: GLuint = 0
    private var texture: GLuint = 0
    private var width: GLsizei = 0
    private var height: GLsizei = 0
    
    init(dylibPath: String, isoPath: String) {
        self.dylibPath = dylibPath
        self.isoPath = isoPath
        globalLibretroFrontend = self
        setupDirectories()
        setupGamepadHandling()
    }
    
    deinit {
        stopEmulation()
        globalLibretroFrontend = nil
    }
    
    func launch() throws {
        log("Launching emulator...")
        
        do {
            try setupCore()
            isInitialized = true
            log("Core initialized successfully")
            
            if loadGame(at: isoPath) {
                isGameLoaded = true
                log("Game loaded successfully")
                
                setupOpenGLContext()
                startEmulatorLoop()
                log("Emulator launched successfully")
            } else {
                throw LibretroError.gameLoadFailed
            }
        } catch {
            log("Error launching emulator: \(error)")
            errorMessage = error.localizedDescription
            throw error
        }
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
        
        if let context = glContext {
            if EAGLContext.current() == context {
                EAGLContext.setCurrent(nil)
            }
        }
        
        glContext = nil
        
        log("Emulator stopped")
    }
    
    // MARK: - Private Methods
    
    private func setupDirectories() {
        let fileManager = FileManager.default
        let documentsPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first!
        
        let systemDir = (documentsPath as NSString).appendingPathComponent("system")
        let savesDir = (documentsPath as NSString).appendingPathComponent("saves")
        let assetsDir = (systemDir as NSString).appendingPathComponent("PPSSPP")
        
        try? fileManager.createDirectory(
            atPath: systemDir, withIntermediateDirectories: true, attributes: nil)
        try? fileManager.createDirectory(
            atPath: savesDir, withIntermediateDirectories: true, attributes: nil)
        try? fileManager.createDirectory(
            atPath: assetsDir, withIntermediateDirectories: true, attributes: nil)
        
        log("System directory: \(systemDir)")
        log("Saves directory: \(savesDir)")
        log("Assets directory: \(assetsDir)")
    }
    
    private func setupCore() throws {
        log("Setting up core from path: \(dylibPath)")
        guard let handle = dlopen(dylibPath, RTLD_LAZY) else {
            throw LibretroError.failedToLoadCore(String(cString: dlerror()))
        }
        coreHandle = handle
        
        guard
            let retro_set_environment = dlsym(handle, "retro_set_environment").map({ unsafeBitCast($0, to: (@convention(c) (@convention(c) (Int32, UnsafeMutableRawPointer?) -> Bool) -> Void).self) }),
            let retro_init = dlsym(handle, "retro_init").map({ unsafeBitCast($0, to: (@convention(c) () -> Void).self) }),
            let retro_deinit = dlsym(handle, "retro_deinit").map({ unsafeBitCast($0, to: (@convention(c) () -> Void).self) }),
            let retro_run = dlsym(handle, "retro_run").map({ unsafeBitCast($0, to: (@convention(c) () -> Void).self) }),
            let retro_set_video_refresh = dlsym(handle, "retro_set_video_refresh").map({ unsafeBitCast($0, to: (@convention(c) (@convention(c) (UnsafeRawPointer?, UInt32, UInt32, Int) -> Void) -> Void).self) }),
            let retro_set_input_poll = dlsym(handle, "retro_set_input_poll").map({ unsafeBitCast($0, to: (@convention(c) (@convention(c) () -> Void) -> Void).self) }),
            let retro_set_input_state = dlsym(handle, "retro_set_input_state").map({ unsafeBitCast($0, to: (@convention(c) (@convention(c) (UInt32, UInt32, UInt32, UInt32) -> Int16) -> Void).self) }),
            let retro_get_system_av_info = dlsym(handle, "retro_get_system_av_info").map({ unsafeBitCast($0, to: (@convention(c) (UnsafeMutableRawPointer) -> Void).self) }),
            let retro_load_game = dlsym(handle, "retro_load_game").map({ unsafeBitCast($0, to: (@convention(c) (UnsafeMutableRawPointer) -> Bool).self) })


        else {
            throw LibretroError.symbolNotFound("Core function")
        }
        
        retro_set_environment(swiftEnvironCallback)
        retro_set_video_refresh(videoRefreshCallback)
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
    
    private func startEmulatorLoop() {
        log("Starting emulator loop...")
        isRunning = true
        
        displayLink = CADisplayLink(target: self, selector: #selector(step))
        displayLink?.add(to: .main, forMode: .common)
    }
    
    @objc private func step(displayLink: CADisplayLink) {
        retro_run?()
    }
    
    // MARK: - Callback Methods
    
    func environCallback(_ cmd: Int32, _ data: UnsafeMutableRawPointer?) -> Bool {
        switch cmd {
        case RETRO_ENVIRONMENT_GET_LOG_INTERFACE:
            if let data = data?.assumingMemoryBound(to: retro_log_callback.self) {
                return true
            }
            
        case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY:
            if let data = data?.assumingMemoryBound(to: UnsafePointer<CChar>?.self) {
                let systemDir =
                    (NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)
                    .first! as NSString).appendingPathComponent("system")
                data.pointee = (systemDir as NSString).utf8String
                return true
            }
            
        case RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY:
            if let data = data?.assumingMemoryBound(to: UnsafePointer<CChar>?.self) {
                let savesDir =
                    (NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)
                    .first! as NSString).appendingPathComponent("saves")
                data.pointee = (savesDir as NSString).utf8String
                return true
            }
            
        case RETRO_ENVIRONMENT_GET_LANGUAGE:
            if let data = data?.assumingMemoryBound(to: UInt32.self) {
                data.pointee = RETRO_LANGUAGE_ENGLISH.rawValue
                return true
            }

        case RETRO_ENVIRONMENT_GET_VARIABLE:
            if let data = data?.assumingMemoryBound(to: retro_variable.self) {
                if let key = data.pointee.key {
                    let variableName = String(cString: key)
                    print("Core requesting variable: \(variableName)")

                    switch variableName {
                    case "ppsspp_rendering_mode":
                        data.pointee.value = "hardware".withCString { UnsafePointer($0) }
                        return true
                    case "ppsspp_auto_frameskip":
                        data.pointee.value = "true".withCString { UnsafePointer($0) }
                        return true
                    default:
                        return false
                    }
                } else {
                    print("Core requested variable with null key")
                    return false
                }
            }

        case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT:
            if let data = data?.assumingMemoryBound(to: retro_pixel_format.self) {
                let format = data.pointee
                if format == .RETRO_PIXEL_FORMAT_XRGB8888 {
                    self.currentPixelFormat = format
                    log("Pixel format set to XRGB8888")
                    return true
                } else {
                    log("Unsupported pixel format requested: \(format)")
                    return false
                }
            }
            
        case RETRO_ENVIRONMENT_SET_HW_RENDER:
            if let data = data?.assumingMemoryBound(to: retro_hw_render_callback.self) {
                let contextType = data.pointee.context_type
                log("Received HW render request with context type: \(contextType)")
                
                data.pointee.get_current_framebuffer = { [weak self] in
                    return self?.framebuffer ?? 0
                }
                data.pointee.get_proc_address = { symbol in
                    return self.getProcAddress(for: symbol)
                }
                return true
            }
            
        default:
            log("Unhandled environment call: \(cmd)")
            return false
        }
        
        return false
    }
    
    private let videoRefreshCallback: @convention(c) (UnsafeRawPointer?, UInt32, UInt32, Int) -> Void = { (data, width, height, pitch) in
        guard let frontend = globalLibretroFrontend else { return }
        
        if data == RETRO_HW_FRAME_BUFFER_VALID {
            frontend.renderHardwareFrame()
        }
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
    
    // MARK: - OpenGL Methods
    
    private func setupOpenGLContext() {
        glContext = EAGLContext(api: .openGLES2)
        EAGLContext.setCurrent(glContext)
        
        glGenFramebuffers(1, &framebuffer)
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), framebuffer)
        
        glGenRenderbuffers(1, &renderbuffer)
        glBindRenderbuffer(GLenum(GL_RENDERBUFFER), renderbuffer)
        
        glFramebufferRenderbuffer(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_RENDERBUFFER), renderbuffer)
        
        glGenTextures(1, &texture)
        glBindTexture(GLenum(GL_TEXTURE_2D), texture)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), GL_LINEAR)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MAG_FILTER), GL_LINEAR)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), GL_CLAMP_TO_EDGE)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), GL_CLAMP_TO_EDGE)
        
        // Get system AV info to set up the viewport
        var avInfo = retro_system_av_info(
            geometry: retro_game_geometry(base_width: 0, base_height: 0, max_width: 0, max_height: 0, aspect_ratio: 0),
            timing: retro_system_timing(fps: 0, sample_rate: 0)
        )
        
        withUnsafeMutablePointer(to: &avInfo) { ptr in
            retro_get_system_av_info?(UnsafeMutableRawPointer(ptr))
        }
        
        width = GLsizei(avInfo.geometry.base_width)
        height = GLsizei(avInfo.geometry.base_height)
        
        glViewport(0, 0, width, height)
    }
    
    private func renderHardwareFrame() {
        guard let context = glContext, EAGLContext.current() != context else { return }
        EAGLContext.setCurrent(context)
        
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), framebuffer)
        glViewport(0, 0, width, height)
        
        // Your rendering code here
        // For example:
        glClearColor(0, 0, 0, 1)
        glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
        
        // Present the rendered frame
        glBindRenderbuffer(GLenum(GL_RENDERBUFFER), renderbuffer)
        context.presentRenderbuffer(Int(GL_RENDERBUFFER))
    }
    
    private func getProcAddress(for symbol: UnsafePointer<Int8>) -> UnsafeMutableRawPointer? {
        let name = String(cString: symbol)
        let handle = dlopen(nil, RTLD_LAZY)
        defer { dlclose(handle) }
        return dlsym(handle, name)
    }
    
    // MARK: - Utility Methods
    
    private func log(_ message: String) {
        print(message)
        DispatchQueue.main.async {
            self.logMessages.append(message)
        }
    }
    
    private func setupGamepadHandling() {
            NotificationCenter.default.addObserver(
                self, selector: #selector(handleControllerConnected),
                name: .GCControllerDidConnect, object: nil)
            NotificationCenter.default.addObserver(
                self, selector: #selector(handleControllerDisconnected),
                name: .GCControllerDidDisconnect, object: nil)

            for gamepad in GCController.controllers() {
                configureGamepadHandlers(gamepad)
            }
        }

        @objc private func handleControllerConnected(_ notification: Notification) {
            guard let gamepad = notification.object as? GCController else { return }
            configureGamepadHandlers(gamepad)
        }

        @objc private func handleControllerDisconnected(_ notification: Notification) {
            // Handle disconnected controller if needed
        }

        private func configureGamepadHandlers(_ gamepad: GCController) {
            gamepad.extendedGamepad?.valueChangedHandler = { [weak self] (gamepad, element) in
                self?.handleGamepadInput(gamepad: gamepad)
            }
        }

        private func handleGamepadInput(gamepad: GCExtendedGamepad) {
            let buttonMappings: [(GCControllerButtonInput?, UInt32)] = [
                (gamepad.buttonA, RETRO_DEVICE_ID_JOYPAD.B),
                (gamepad.buttonB, RETRO_DEVICE_ID_JOYPAD.A),
                (gamepad.buttonX, RETRO_DEVICE_ID_JOYPAD.Y),
                (gamepad.buttonY, RETRO_DEVICE_ID_JOYPAD.X),
                (gamepad.leftShoulder, RETRO_DEVICE_ID_JOYPAD.L),
                (gamepad.rightShoulder, RETRO_DEVICE_ID_JOYPAD.R),
                (gamepad.dpad.up, RETRO_DEVICE_ID_JOYPAD.UP),
                (gamepad.dpad.down, RETRO_DEVICE_ID_JOYPAD.DOWN),
                (gamepad.dpad.left, RETRO_DEVICE_ID_JOYPAD.LEFT),
                (gamepad.dpad.right, RETRO_DEVICE_ID_JOYPAD.RIGHT),
                (gamepad.buttonMenu, RETRO_DEVICE_ID_JOYPAD.START),
                (gamepad.buttonOptions, RETRO_DEVICE_ID_JOYPAD.SELECT),
            ]

            for (button, retroButton) in buttonMappings {
                if let button = button {
                    updateInputState(port: 0, buttonId: retroButton, isPressed: button.isPressed)
                }
            }

            // Handle analog sticks
            updateAnalogState(gamepad.leftThumbstick, port: 0, axisX: 0, axisY: 1)
            updateAnalogState(gamepad.rightThumbstick, port: 0, axisX: 2, axisY: 3)
        }

        private func updateInputState(port: UInt32, buttonId: UInt32, isPressed: Bool) {
            if inputState[port] == nil {
                inputState[port] = [:]
            }
            inputState[port]?[buttonId] = isPressed
        }

        private func updateAnalogState(_ stick: GCControllerDirectionPad, port: UInt32, axisX: UInt32, axisY: UInt32) {
            let deadzone: Float = 0.2
            let x = abs(stick.xAxis.value) > deadzone ? stick.xAxis.value : 0
            let y = abs(stick.yAxis.value) > deadzone ? stick.yAxis.value : 0

            updateInputState(port: port, buttonId: axisX, isPressed: x != 0)
            updateInputState(port: port, buttonId: axisY, isPressed: y != 0)

            // You might want to scale these values depending on what the core expects
            inputState[port]?[axisX] = x > 0
            inputState[port]?[axisY] = y > 0
        }
    }

    struct retro_log_callback {
        var log: (@convention(c) (UInt32, UnsafePointer<CChar>?) -> Void)?
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

    struct retro_hw_render_callback {
        var context_type: UInt32
        var context_reset: (() -> Void)?
        var get_current_framebuffer: (() -> UInt32)?
        var get_proc_address: ((UnsafePointer<Int8>) -> UnsafeMutableRawPointer?)?
        var depth: Bool
        var stencil: Bool
        var bottom_left_origin: Bool
        var version_major: UInt32
        var version_minor: UInt32
        var cache_context: Bool
        var context_destroy: (() -> Void)?
        var debug_context: Bool
    }

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

    let RETRO_HW_FRAME_BUFFER_VALID = UnsafeRawPointer(bitPattern: -1)

    // Example usage:
    // let libretro = LibretroFrontend(dylibPath: "/path/to/ppsspp_libretro.dylib", isoPath: "/path/to/game.iso")
    // do {
    //     try libretro.launch()
    // } catch {
    //     print("Error: \(error)")
    // }
