import SwiftUI
import CoreGraphics

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
                
                Button(action: {
                    do {
                        if libretroFrontend.isLaunched {
                            libretroFrontend.stopEmulation()
                        } else {
                            try libretroFrontend.launch()
                        }
                    } catch {
                        print("Error launching emulator: \(error)")
                    }
                }) {
                    Text(libretroFrontend.isLaunched ? "Stop" : "Launch")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(libretroFrontend.isLaunched ? Color.red : Color.blue)
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

#if DEBUG
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
#endif
