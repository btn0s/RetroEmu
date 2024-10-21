import AVFoundation
import CoreGraphics
import Foundation
import GLKit
import GameController
import OpenGLES

// Global variable to hold our LibretroFrontend instance
var globalLibretroFrontend: LibretroFrontend?

@_cdecl("swiftEnvironmentCallback")
public func swiftEnvironmentCallback(cmd: Int32, data: UnsafeMutableRawPointer?) -> Bool {
    return globalLibretroFrontend?.handleEnvironment(cmd, data) ?? false
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
    private var retro_get_system_av_info:
        (@convention(c) (UnsafeMutablePointer<retro_system_av_info>) -> Void)?
    private var retro_load_game: (@convention(c) (UnsafePointer<retro_game_info>) -> Bool)?
    private var retro_init: (() -> Void)?
    private var retro_deinit: (() -> Void)?

    private var currentPixelFormat: retro_pixel_format = RETRO_PIXEL_FORMAT_XRGB8888
    private var inputState: [Int32: [Int32: Bool]] = [:]

    var glContext: EAGLContext?
    var eaglLayer: CAEAGLLayer?
    var hwRenderCallback: retro_hw_render_callback?
    
    var framebuffer: GLuint = 0
    var colorRenderbuffer: GLuint = 0
    var depthRenderbuffer: GLuint = 0

    init(dylibPath: String, isoPath: String) {
        self.dylibPath = dylibPath
        self.isoPath = isoPath

        copyPPSSPPResources {
            globalLibretroFrontend = self
            self.setupDirectories()
            self.setupGamepadHandling()
        }
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
        let documentsPath = NSSearchPathForDirectoriesInDomains(
            .documentDirectory, .userDomainMask, true
        ).first!

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
            let retro_set_environment = dlsym(handle, "retro_set_environment").map({
                unsafeBitCast(
                    $0,
                    to: (@convention(c) (@convention(c) (Int32, UnsafeMutableRawPointer?) -> Bool)
                        -> Void).self)
            }),
            let retro_init = dlsym(handle, "retro_init").map({
                unsafeBitCast($0, to: (@convention(c) () -> Void).self)
            }),
            let retro_deinit = dlsym(handle, "retro_deinit").map({
                unsafeBitCast($0, to: (@convention(c) () -> Void).self)
            }),
            let retro_run = dlsym(handle, "retro_run").map({
                unsafeBitCast($0, to: (@convention(c) () -> Void).self)
            }),
            let retro_set_video_refresh = dlsym(handle, "retro_set_video_refresh").map({
                unsafeBitCast(
                    $0,
                    to: (@convention(c) (
                        @convention(c) (UnsafeRawPointer?, Int32, Int32, Int) -> Void
                    ) -> Void).self)
            }),
            let retro_set_input_poll = dlsym(handle, "retro_set_input_poll").map({
                unsafeBitCast($0, to: (@convention(c) (@convention(c) () -> Void) -> Void).self)
            }),
            let retro_set_input_state = dlsym(handle, "retro_set_input_state").map({
                unsafeBitCast(
                    $0,
                    to: (@convention(c) (@convention(c) (Int32, Int32, Int32, Int32) -> Int16) ->
                        Void).self)
            }),
            let retro_get_system_av_info = dlsym(handle, "retro_get_system_av_info").map({
                unsafeBitCast(
                    $0,
                    to: (@convention(c) (UnsafeMutablePointer<retro_system_av_info>) -> Void).self)
            }),
            let retro_load_game = dlsym(handle, "retro_load_game").map({
                unsafeBitCast(
                    $0, to: (@convention(c) (UnsafePointer<retro_game_info>) -> Bool).self)
            })
        else {
            throw LibretroError.symbolNotFound("Core function")
        }

        retro_set_environment(swiftEnvironmentCallback)
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

        hwRenderCallback?.context_destroy()
        hwRenderCallback?.context_reset()

        displayLink = CADisplayLink(target: self, selector: #selector(step))
        displayLink?.add(to: .main, forMode: .common)
    }

    @objc func step(displayLink: CADisplayLink) {
        retro_run?()
    }

    // MARK: - Environment Callback

    func handleEnvironment(_ cmd: Int32, _ data: UnsafeMutableRawPointer?) -> Bool {
        switch cmd {
        case RETRO_ENVIRONMENT_GET_LOG_INTERFACE:
            if let data = data?.assumingMemoryBound(to: retro_log_callback.self) {
                data.pointee.log = { (level: UInt32, fmt: UnsafePointer<CChar>?) in
                    guard let fmt = fmt else { return }
                    
                    let message = String(cString: fmt)
                    
                    let logLevel: String
                    switch level {
                        case 0: logLevel = "DEBUG"
                        case 1: logLevel = "INFO"
                        case 2: logLevel = "WARN"
                        case 3: logLevel = "ERROR"
                        default: logLevel = "UNKNOWN"
                    }
                    
                    print("[\(logLevel)] \(message)")
                }
                return true
            }

        case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY:
            if let data = data?.assumingMemoryBound(to: UnsafePointer<Int8>?.self) {
                let systemDir =
                    (NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)
                    .first! as NSString).appendingPathComponent("system")
                data.pointee = (systemDir as NSString).utf8String
                return true
            }

        case RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY:
            if let data = data?.assumingMemoryBound(to: UnsafePointer<Int8>?.self) {
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

        case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT:
            if let data = data?.assumingMemoryBound(to: retro_pixel_format.self) {
                let format = data.pointee
                if format == RETRO_PIXEL_FORMAT_XRGB8888 {
                    self.currentPixelFormat = format
                    return true
                }
            }

        case RETRO_ENVIRONMENT_GET_VARIABLE:
            if let data = data?.assumingMemoryBound(to: retro_variable.self) {
                if let key = data.pointee.key {
                    let variableName = String(cString: key)
                    switch variableName {
                    case "ppsspp_backend":
                        data.pointee.value = "GLES3".withCString { UnsafePointer($0) }
                    case "ppsspp_rendering_mode":
                        data.pointee.value = "hardware".withCString { UnsafePointer($0) }
                    default:
                        return false
                    }
                    return true
                }
            }

        case RETRO_ENVIRONMENT_SET_HW_RENDER:
            if let data = data?.assumingMemoryBound(to: retro_hw_render_callback.self) {
                print("Setting up hardware rendering with context type: \(data.pointee.context_type)")
                setupHardwareRendering(data.pointee)
                data.pointee = self.hwRenderCallback!
                return true
            }

        default:
            log("Unhandled environment call: \(cmd)")
            return false
        }

        return false
    }

    // MARK: - Hardware Rendering

    private func setupHardwareRendering(_ hwRender: retro_hw_render_callback) {
        var hwRenderCallback = hwRender

        print("Setting up hardware rendering with context type: \(hwRender.context_type)")

        let api: EAGLRenderingAPI = hwRender.context_type == RETRO_HW_CONTEXT_OPENGLES3 ? .openGLES3 : .openGLES2
        glContext = EAGLContext(api: api)

        if let context = glContext {
            EAGLContext.setCurrent(context)

            eaglLayer = CAEAGLLayer()
            eaglLayer?.drawableProperties = [
                kEAGLDrawablePropertyRetainedBacking: false,
                kEAGLDrawablePropertyColorFormat: kEAGLColorFormatRGBA8
            ]
            
            let width: GLsizei = 640, height: GLsizei = 480

            glGenFramebuffers(1, &framebuffer);
            glBindFramebuffer(GLenum(GL_FRAMEBUFFER), framebuffer);
            
            glGenRenderbuffers(1, &colorRenderbuffer);
            glBindRenderbuffer(GLenum(GL_RENDERBUFFER), colorRenderbuffer);
            glRenderbufferStorage(GLenum(GL_RENDERBUFFER), GLenum(GL_RGBA8), width, height);
            glFramebufferRenderbuffer(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_RENDERBUFFER), colorRenderbuffer);
            
            glGenRenderbuffers(1, &depthRenderbuffer);
            glBindRenderbuffer(GLenum(GL_RENDERBUFFER), depthRenderbuffer);
            glRenderbufferStorage(GLenum(GL_RENDERBUFFER), GLenum(GL_DEPTH_COMPONENT16), width, height);
            glFramebufferRenderbuffer(GLenum(GL_FRAMEBUFFER), GLenum(GL_DEPTH_ATTACHMENT), GLenum(GL_RENDERBUFFER), depthRenderbuffer);
        
            var status: GLenum = glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER)) ;
            if(status != GL_FRAMEBUFFER_COMPLETE) {
                print("Framebuffer not complete: \(status)")
            } else {
                print("Framebuffer complete: \(framebuffer)")
            }
            
            // Set the get_current_framebuffer callback
            hwRenderCallback.get_current_framebuffer = getCurrentFramebuffer

            hwRenderCallback.get_proc_address = { symbolPtr in
                guard let symbol = symbolPtr else { return nil }
                let symbolName = String(cString: symbol)
                return unsafeBitCast(dlsym(dlopen(nil, RTLD_LAZY), symbolName), to: retro_proc_address_t.self)
            }

            // Save the modified callback
            self.hwRenderCallback = hwRenderCallback
        }
    }

    // Static method to get the current framebuffer
    let getCurrentFramebuffer: retro_hw_get_current_framebuffer_t = {
        guard let frontend = globalLibretroFrontend else {
            print("globalLibretroFrontend is nil")
            return 0
        }
        print("Returning framebuffer: \(frontend.framebuffer)")
        return UInt(frontend.framebuffer)
    }

    // MARK: - Callbacks

    private let videoRefreshCallback:
        @convention(c) (UnsafeRawPointer?, Int32, Int32, Int) -> Void = {
            (data, width, height, pitch) in
            guard let frontend = globalLibretroFrontend else { return }
            frontend.handleVideoRefresh(data, width: width, height: height, pitch: pitch)
        }

    private let inputPollCallback: @convention(c) () -> Void = {
        globalLibretroFrontend?.pollInputs()
    }

    private let inputStateCallback: @convention(c) (Int32, Int32, Int32, Int32) -> Int16 = {
        (port, device, index, id) in
        return globalLibretroFrontend?.handleInputState(
            port: port, device: device, index: index, id: id) ?? 0
    }

    private func handleVideoRefresh(
        _ data: UnsafeRawPointer?, width: Int32, height: Int32, pitch: Int
    ) {
        // Handle video refresh, create CGImage if needed
    }

    private func pollInputs() {
        // Poll inputs from game controllers
    }

    private func handleInputState(port: Int32, device: Int32, index: Int32, id: Int32) -> Int16 {
        return inputState[port]?[id] == true ? 1 : 0
    }

    // MARK: - Gamepad Handling

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
        let buttonMappings: [(GCControllerButtonInput?, Int32)] = [
            (gamepad.buttonA, RETRO_DEVICE_ID_JOYPAD_B),
            (gamepad.buttonB, RETRO_DEVICE_ID_JOYPAD_A),
            (gamepad.buttonX, RETRO_DEVICE_ID_JOYPAD_Y),
            (gamepad.buttonY, RETRO_DEVICE_ID_JOYPAD_X),
            (gamepad.leftShoulder, RETRO_DEVICE_ID_JOYPAD_L),
            (gamepad.rightShoulder, RETRO_DEVICE_ID_JOYPAD_R),
            (gamepad.dpad.up, RETRO_DEVICE_ID_JOYPAD_UP),
            (gamepad.dpad.down, RETRO_DEVICE_ID_JOYPAD_DOWN),
            (gamepad.dpad.left, RETRO_DEVICE_ID_JOYPAD_LEFT),
            (gamepad.dpad.right, RETRO_DEVICE_ID_JOYPAD_RIGHT),
            (gamepad.buttonMenu, RETRO_DEVICE_ID_JOYPAD_START),
            (gamepad.buttonOptions, RETRO_DEVICE_ID_JOYPAD_SELECT),
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

    private func updateInputState(port: Int32, buttonId: Int32, isPressed: Bool) {
        if inputState[port] == nil {
            inputState[port] = [:]
        }
        inputState[port]?[buttonId] = isPressed
    }

    private func updateAnalogState(
        _ stick: GCControllerDirectionPad, port: Int32, axisX: Int32, axisY: Int32
    ) {
        let deadzone: Float = 0.2
        let x = abs(stick.xAxis.value) > deadzone ? stick.xAxis.value : 0
        let y = abs(stick.yAxis.value) > deadzone ? stick.yAxis.value : 0

        updateInputState(port: port, buttonId: axisX, isPressed: x != 0)
        updateInputState(port: port, buttonId: axisY, isPressed: y != 0)

        // You might want to scale these values depending on what the core expects
        inputState[port]?[axisX] = x > 0
        inputState[port]?[axisY] = y > 0
    }

    // MARK: - Utility Methods

    private func copyPPSSPPResources(completion: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let fileManager = FileManager.default
            guard
                let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask)
                    .first
            else {
                print("Unable to access Documents directory")
                DispatchQueue.main.async { completion() }
                return
            }

            let systemDir = documentsPath.appendingPathComponent("system")
            let ppssppDestination = systemDir.appendingPathComponent("PPSSPP")

            // Create system directory if it doesn't exist
            if !fileManager.fileExists(atPath: systemDir.path) {
                do {
                    try fileManager.createDirectory(
                        at: systemDir, withIntermediateDirectories: true, attributes: nil)
                } catch {
                    print("Failed to create system directory: \(error)")
                    DispatchQueue.main.async { completion() }
                    return
                }
            }

            // Check if PPSSPP folder already exists in system directory
            if fileManager.fileExists(atPath: ppssppDestination.path) {
                print("PPSSPP resources already exist in system directory")
                DispatchQueue.main.async { completion() }
                return
            }

            guard let ppssppSourceURL = Bundle.main.url(forResource: "PPSSPP", withExtension: nil)
            else {
                print("PPSSPP resources not found in app bundle")
                DispatchQueue.main.async { completion() }
                return
            }

            do {
                try fileManager.copyItem(at: ppssppSourceURL, to: ppssppDestination)
                print("Successfully copied PPSSPP resources to system directory")
            } catch {
                print("Failed to copy PPSSPP resources: \(error)")
            }

            DispatchQueue.main.async { completion() }
        }
    }

    private func log(_ message: String) {
        print(message)
        DispatchQueue.main.async {
            self.logMessages.append(message)
        }
    }
}

struct retro_log_callback {
    var log: (@convention(c) (UInt32, UnsafePointer<CChar>?) -> Void)?
}

