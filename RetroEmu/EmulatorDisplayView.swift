import SwiftUI

struct EmulatorDisplayView: View {
    @Binding var videoFrame: CGImage?
    @Binding var isPresented: Bool
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.edgesIgnoringSafeArea(.all)
                
                if let videoFrame = videoFrame {
                    Image(videoFrame, scale: 1.0, label: Text("Emulator Output"))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else {
                    Text("No video output")
                        .foregroundColor(.white)
                }
                
                VStack {
                    HStack {
                        Spacer()
                        Button(action: {
                            isPresented = false
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.white)
                                .font(.title)
                                .padding()
                        }
                    }
                    Spacer()
                }
            }
        }
        .statusBar(hidden: true)
    }
}
