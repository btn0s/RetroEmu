import Foundation
import GLKit

class OpenGLRenderer {
    private var context: EAGLContext?
    private var renderBuffer: GLuint = 0
    private var frameBuffer: GLuint = 0
    private var texture: GLuint = 0
    private var width: Int = 0
    private var height: Int = 0
    
    init() {
        context = EAGLContext(api: .openGLES2)
        EAGLContext.setCurrent(context)
        setupGL()
    }
    
    private func setupGL() {
        glGenFramebuffers(1, &frameBuffer)
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), frameBuffer)
        
        glGenRenderbuffers(1, &renderBuffer)
        glBindRenderbuffer(GLenum(GL_RENDERBUFFER), renderBuffer)
        
        glFramebufferRenderbuffer(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_RENDERBUFFER), renderBuffer)
        
        glGenTextures(1, &texture)
        glBindTexture(GLenum(GL_TEXTURE_2D), texture)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), GL_LINEAR)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MAG_FILTER), GL_LINEAR)
    }
    
    func updateTexture(with data: UnsafeRawPointer, width: Int, height: Int) {
        self.width = width
        self.height = height
        
        glBindTexture(GLenum(GL_TEXTURE_2D), texture)
        glTexImage2D(GLenum(GL_TEXTURE_2D), 0, GL_RGBA, GLsizei(width), GLsizei(height), 0, GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), data)
    }
    
    func render() {
        glClearColor(0, 0, 0, 1)
        glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
        
        glViewport(0, 0, GLsizei(width), GLsizei(height))
        
        glBindTexture(GLenum(GL_TEXTURE_2D), texture)
        
        // Simple fullscreen quad rendering
        let vertices: [GLfloat] = [
            -1, -1,
            1, -1,
            -1,  1,
            1,  1
        ]
        
        let texCoords: [GLfloat] = [
            0, 1,
            1, 1,
            0, 0,
            1, 0
        ]
        
        glEnableVertexAttribArray(0)
        glEnableVertexAttribArray(1)
        
        glVertexAttribPointer(0, 2, GLenum(GL_FLOAT), GLboolean(GL_FALSE), 0, vertices)
        glVertexAttribPointer(1, 2, GLenum(GL_FLOAT), GLboolean(GL_FALSE), 0, texCoords)
        
        glDrawArrays(GLenum(GL_TRIANGLE_STRIP), 0, 4)
        
        context?.presentRenderbuffer(Int(GL_RENDERBUFFER))
    }
}
