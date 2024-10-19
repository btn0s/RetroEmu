import SwiftUI
import GLKit

struct GLView: UIViewRepresentable {
    var libretroFrontend: LibretroFrontend

    func makeUIView(context: Context) -> GLKView {
        guard let glContext = libretroFrontend.glContext else {
            fatalError("OpenGL context not initialized")
        }
        
        let glView = GLKView(frame: .zero, context: glContext)
        glView.delegate = context.coordinator
        glView.enableSetNeedsDisplay = false
        glView.contentScaleFactor = UIScreen.main.scale
        
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
            // This method is called when the view needs to be redrawn
            // We don't need to do anything here as the rendering is handled in the step method
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
            if libretroFrontend.isInitialized {
                GLView(libretroFrontend: libretroFrontend)
                    .edgesIgnoringSafeArea(.all)
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
