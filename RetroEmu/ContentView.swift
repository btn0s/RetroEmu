import SwiftUI
import CoreGraphics
import UIKit

struct ContentView: View {
    @StateObject private var libretroFrontend: LibretroFrontend

    init() {
        let dylibPath = Bundle.main.path(forResource: "ppsspp_libretro", ofType: "dylib", inDirectory: "Frameworks") ?? ""
        let isoPath = Bundle.main.path(forResource: "gow", ofType: "iso") ?? ""
        _libretroFrontend = StateObject(wrappedValue: LibretroFrontend(dylibPath: dylibPath, isoPath: isoPath))
    }

    var body: some View {
        ZStack {
            if let videoFrame = libretroFrontend.videoFrame {
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
                        libretroFrontend.initializeEmulator()
                    }) {
                        Text("Initialize")
                            .padding()
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }
                    .disabled(!libretroFrontend.canInitialize)
                    
                    Button(action: {
                        libretroFrontend.loadGame()
                    }) {
                        Text("Load Game")
                            .padding()
                            .background(Color.green)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }
                    .disabled(!libretroFrontend.canLoadGame)
                    
                    Button(action: {
                        if libretroFrontend.isRunning {
                            libretroFrontend.stopEmulation()
                        } else {
                            libretroFrontend.runCore()
                        }
                    }) {
                        Text(libretroFrontend.isRunning ? "Stop" : "Run")
                            .padding()
                            .background(libretroFrontend.isRunning ? Color.red : Color.orange)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }
                    .disabled(!libretroFrontend.canRun)
                }
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

#if DEBUG
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
#endif
