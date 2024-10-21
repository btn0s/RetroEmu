import SwiftUI
import GLKit

struct GLView: UIViewRepresentable {
    var libretroFrontend: LibretroFrontend

    func makeUIView(context: Context) -> GLKView {
        guard let glContext = libretroFrontend.glContext else {
            fatalError("OpenGL context not initialized")
        }
        
        let glView = GLKView(frame: CGRect(x: 0, y: 0, width: 320, height: 240), context: glContext)
        glView.delegate = context.coordinator
        glView.enableSetNeedsDisplay = false
        glView.contentScaleFactor = UIScreen.main.scale
        
        // Add a border to the GLKView
        glView.layer.borderWidth = 2.0
        glView.layer.borderColor = UIColor.red.cgColor
        
        libretroFrontend.eaglLayer = glView.layer as? CAEAGLLayer
        
        return glView
    }

    func updateUIView(_ uiView: GLKView, context: Context) {
        // Update view if needed
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, GLKViewDelegate {
        var parent: GLView

        init(_ parent: GLView) {
            self.parent = parent
        }

        func glkView(_ view: GLKView, drawIn rect: CGRect) {
            print("glkView called with rect: \(rect)")
            guard let context = parent.libretroFrontend.glContext else {
                print("OpenGL context is nil")
                return
            }
            EAGLContext.setCurrent(context)
            
            print("Binding framebuffer: \(parent.libretroFrontend.framebuffer)")
            glBindFramebuffer(GLenum(GL_FRAMEBUFFER), parent.libretroFrontend.framebuffer)
            glViewport(0, 0, GLsizei(view.bounds.width), GLsizei(view.bounds.height))
            
            // Fill the view with white
            glClearColor(1.0, 1.0, 1.0, 1.0)
            glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
            
            print("Binding color renderbuffer: \(parent.libretroFrontend.colorRenderbuffer)")
            glBindRenderbuffer(GLenum(GL_RENDERBUFFER), parent.libretroFrontend.colorRenderbuffer)
            context.presentRenderbuffer(Int(GL_RENDERBUFFER))
            
            print("Finished drawing")
        }
    }
}

struct ContentView: View {
    @StateObject private var libretroFrontend: LibretroFrontend

    init() {
        let dylibPath = Bundle.main.path(forResource: "ppsspp_libretro_debug", ofType: "dylib", inDirectory: "Frameworks") ?? ""
        let isoPath = Bundle.main.path(forResource: "gow", ofType: "iso") ?? ""
        _libretroFrontend = StateObject(wrappedValue: LibretroFrontend(dylibPath: dylibPath, isoPath: isoPath))
    }

    var body: some View {
        ZStack {
            Color.gray.edgesIgnoringSafeArea(.all) // Add a background color
            
            if libretroFrontend.isInitialized {
                GLView(libretroFrontend: libretroFrontend)
                    .border(Color.blue, width: 2) // Add a border to the SwiftUI view
            } else {
                Color.black.edgesIgnoringSafeArea(.all)
            }
            
            VStack {
                Spacer()
                
                Button(action: {
                    do {
                        if libretroFrontend.isRunning {
                            libretroFrontend.stopEmulation()
                        } else {
                            try libretroFrontend.launch()
                        }
                    } catch {
                        print("Error launching emulator: \(error)")
                    }
                }) {
                    Text(libretroFrontend.isRunning ? "Stop" : "Launch")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(libretroFrontend.isRunning ? Color.red : Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
            
            if let errorMessage = libretroFrontend.errorMessage {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .padding()
            }
        }
    }
}
