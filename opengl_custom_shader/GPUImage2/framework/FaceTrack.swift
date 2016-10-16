open class FaceTrack: BasicOperation {
    
    open var radius:Float = 0.25 { didSet { uniformSettings["radius"] = radius } }
    open var scale:Float = 0.5 { didSet { uniformSettings["scale"] = scale } }
    open var center:Position = Position.center { didSet { uniformSettings["center"] = center } }
    
    let fbSize = Size(width: 640, height: 480)
    
    
    
    public init() {
        super.init(fragmentShader:BulgeDistortionFragmentShader, numberOfInputs:1)
        
        center = Position(0.5, 0.7)
        
        ({radius = 0.25})()
        ({scale = 0.8})()
        ({center = Position.center})()
    }
    
}

public let FaceTrackShader = try! String(contentsOfFile: Bundle.main.path(forResource: "FaceTrack", ofType: "cikernel")!, encoding: String.Encoding.utf8)


///////

public let MaskPositionVertexShader = "attribute vec4 position;\n \n void main()\n {\n     gl_Position = position;\n }\n "
public let MaskPositionFragmentShader = "uniform lowp vec3 lineColor;\n \n void main()\n {\n     gl_FragColor = vec4(lineColor, 1.0);\n }\n "

open class MaskGenerator: ImageGenerator {
    let blendFilter = AlphaBlend()
    
    open var lineColor:Color = Color.green { didSet { uniformSettings["lineColor"] = lineColor } }
    open var lineWidth:Float = 1.0 {
        didSet {
            maskShader.use()
            glLineWidth(lineWidth)
        }
    }
    
    let maskShader:ShaderProgram
    var uniformSettings = ShaderUniformSettings()
    
    public override init(size:Size) {
        maskShader = crashOnShaderCompileFailure("LineGenerator"){try sharedImageProcessingContext.programForVertexShader(MaskPositionVertexShader, fragmentShader:MaskPositionFragmentShader)}
        super.init(size:size)
        
        ({lineWidth = 1.0})()
        ({lineColor = Color.red})()
    }
    
    open func positionMask(_ lines:[Line]) {
        
        imageFramebuffer.activateFramebufferForRendering()
        
        maskShader.use()
        uniformSettings.restoreShaderSettings(maskShader)
        
        clearFramebufferWithColor(Color.transparent)
        
        guard let positionAttribute = maskShader.attributeIndex("position") else { fatalError("A position attribute was missing from the shader program during rendering.") }
        
        let lineEndpoints = lines.flatMap{$0.toGLEndpoints()}
        glVertexAttribPointer(positionAttribute, 2, GLenum(GL_FLOAT), 0, 0, lineEndpoints)
        
        glBlendEquation(GLenum(GL_FUNC_ADD))
        glBlendFunc(GLenum(GL_ONE), GLenum(GL_ONE))
        glEnable(GLenum(GL_BLEND))
        
        glDrawArrays(GLenum(GL_LINES), 0, GLsizei(lines.count) * 2)
        
        glDisable(GLenum(GL_BLEND))
        
        notifyTargets()
    }
    
}


open class MaskPictureInput: BasicOperation {
    
    // Consumer setup
    
    open var mix:Float = 0.5 { didSet { uniformSettings["mixturePercent"] = mix } }
    
    
    var imageFramebuffer:Framebuffer!
    var hasProcessedImage:Bool = false
    
    public init(image:CGImage, smoothlyScaleOutput:Bool = false, orientation:ImageOrientation = .portrait) {
        
        super.init(fragmentShader:AlphaBlendFragmentShader, numberOfInputs:2)
        // TODO: Dispatch this whole thing asynchronously to move image loading off main thread
        let widthOfImage = GLint(image.width)
        let heightOfImage = GLint(image.height)
        
        // If passed an empty image reference, CGContextDrawImage will fail in future versions of the SDK.
        guard((widthOfImage > 0) && (heightOfImage > 0)) else { fatalError("Tried to pass in a zero-sized image") }
        
        var widthToUseForTexture = widthOfImage
        var heightToUseForTexture = heightOfImage
        var shouldRedrawUsingCoreGraphics = false
        
        // For now, deal with images larger than the maximum texture size by resizing to be within that limit
        let scaledImageSizeToFitOnGPU = GLSize(sharedImageProcessingContext.sizeThatFitsWithinATextureForSize(Size(width:Float(widthOfImage), height:Float(heightOfImage))))
        if ((scaledImageSizeToFitOnGPU.width != widthOfImage) && (scaledImageSizeToFitOnGPU.height != heightOfImage)) {
            widthToUseForTexture = scaledImageSizeToFitOnGPU.width
            heightToUseForTexture = scaledImageSizeToFitOnGPU.height
            shouldRedrawUsingCoreGraphics = true
        }
        
        if (smoothlyScaleOutput) {
            // In order to use mipmaps, you need to provide power-of-two textures, so convert to the next largest power of two and stretch to fill
            let powerClosestToWidth = ceil(log2(Float(widthToUseForTexture)))
            let powerClosestToHeight = ceil(log2(Float(heightToUseForTexture)))
            
            widthToUseForTexture = GLint(round(pow(2.0, powerClosestToWidth)))
            heightToUseForTexture = GLint(round(pow(2.0, powerClosestToHeight)))
            shouldRedrawUsingCoreGraphics = true
        }
        
        var imageData:UnsafeMutablePointer<GLubyte>!
        var dataFromImageDataProvider:CFData!
        var format = GL_BGRA
        
        if (!shouldRedrawUsingCoreGraphics) {
            /* Check that the memory layout is compatible with GL, as we cannot use glPixelStore to
             * tell GL about the memory layout with GLES.
             */
            if ((image.bytesPerRow != image.width * 4) || (image.bitsPerPixel != 32) || (image.bitsPerComponent != 8))
            {
                shouldRedrawUsingCoreGraphics = true
            } else {
                /* Check that the bitmap pixel format is compatible with GL */
                let bitmapInfo = image.bitmapInfo
                if (bitmapInfo.contains(.floatComponents)) {
                    /* We don't support float components for use directly in GL */
                    shouldRedrawUsingCoreGraphics = true
                } else {
                    let alphaInfo = CGImageAlphaInfo(rawValue:bitmapInfo.rawValue & CGBitmapInfo.alphaInfoMask.rawValue)
                    if (bitmapInfo.contains(.byteOrder32Little)) {
                        /* Little endian, for alpha-first we can use this bitmap directly in GL */
                        if ((alphaInfo != CGImageAlphaInfo.premultipliedFirst) && (alphaInfo != CGImageAlphaInfo.first) && (alphaInfo != CGImageAlphaInfo.noneSkipFirst)) {
                            shouldRedrawUsingCoreGraphics = true
                        }
                        
                        // [] instead of .byteOrderDefault
                    } else if ((bitmapInfo.contains([])) || (bitmapInfo.contains(.byteOrder32Big))) {
                        /* Big endian, for alpha-last we can use this bitmap directly in GL */
                        if ((alphaInfo != CGImageAlphaInfo.premultipliedLast) && (alphaInfo != CGImageAlphaInfo.last) && (alphaInfo != CGImageAlphaInfo.noneSkipLast)) {
                            shouldRedrawUsingCoreGraphics = true
                        } else {
                            /* Can access directly using GL_RGBA pixel format */
                            format = GL_RGBA
                        }
                    }
                }
            }
        }
        
        //    CFAbsoluteTime elapsedTime, startTime = CFAbsoluteTimeGetCurrent();
        
        if (shouldRedrawUsingCoreGraphics) {
            // For resized or incompatible image: redraw
            imageData = UnsafeMutablePointer<GLubyte>.allocate(capacity: Int(widthToUseForTexture * heightToUseForTexture) * 4)
            
            let genericRGBColorspace = CGColorSpaceCreateDeviceRGB()
            
            let imageContext = CGContext(data: imageData, width: Int(widthToUseForTexture), height: Int(heightToUseForTexture), bitsPerComponent: 8, bytesPerRow: Int(widthToUseForTexture) * 4, space: genericRGBColorspace,  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            //        CGContextSetBlendMode(imageContext, kCGBlendModeCopy); // From Technical Q&A QA1708: http://developer.apple.com/library/ios/#qa/qa1708/_index.html
            imageContext?.draw(image, in:CGRect(x:0.0, y:0.0, width:CGFloat(widthToUseForTexture), height:CGFloat(heightToUseForTexture)))
        } else {
            // Access the raw image bytes directly
            dataFromImageDataProvider = image.dataProvider?.data
            imageData = UnsafeMutablePointer<GLubyte>(mutating:CFDataGetBytePtr(dataFromImageDataProvider))
        }
        
        sharedImageProcessingContext.runOperationSynchronously{
            do {
                // TODO: Alter orientation based on metadata from photo
                self.imageFramebuffer = try Framebuffer(context:sharedImageProcessingContext, orientation:orientation, size:GLSize(width:widthToUseForTexture, height:heightToUseForTexture), textureOnly:true)
            } catch {
                fatalError("ERROR: Unable to initialize framebuffer of size (\(widthToUseForTexture), \(heightToUseForTexture)) with error: \(error)")
            }
            
            glBindTexture(GLenum(GL_TEXTURE_2D), self.imageFramebuffer.texture)
            if (smoothlyScaleOutput) {
                glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), GL_LINEAR_MIPMAP_LINEAR)
            }
            
            glTexImage2D(GLenum(GL_TEXTURE_2D), 0, GL_RGBA, widthToUseForTexture, heightToUseForTexture, 0, GLenum(format), GLenum(GL_UNSIGNED_BYTE), imageData)
            
            if (smoothlyScaleOutput) {
                glGenerateMipmap(GLenum(GL_TEXTURE_2D))
            }
            glBindTexture(GLenum(GL_TEXTURE_2D), 0)
        }
        
        if (shouldRedrawUsingCoreGraphics) {
            imageData.deallocate(capacity: Int(widthToUseForTexture * heightToUseForTexture) * 4)
        }
    }
    
    public convenience init(image:UIImage, smoothlyScaleOutput:Bool = false, orientation:ImageOrientation = .portrait) {
        self.init(image:image.cgImage!, smoothlyScaleOutput:smoothlyScaleOutput, orientation:orientation)
    }
    
    public convenience init(imageName:String, smoothlyScaleOutput:Bool = false, orientation:ImageOrientation = .portrait) {
        guard let image = UIImage(named:imageName) else { fatalError("No such image named: \(imageName) in your application bundle") }
        self.init(image:image.cgImage!, smoothlyScaleOutput:smoothlyScaleOutput, orientation:orientation)
    }
    
    open func processImage(_ synchronously:Bool = false) {
        if synchronously {
            sharedImageProcessingContext.runOperationSynchronously{
                self.updateTargetsWithFramebuffer(self.imageFramebuffer)
                self.hasProcessedImage = true
            }
        } else {
            sharedImageProcessingContext.runOperationAsynchronously{
                self.updateTargetsWithFramebuffer(self.imageFramebuffer)
                self.hasProcessedImage = true
            }
        }
    }
    
    open func transmitPreviousImageToTarget(_ target:ImageConsumer, atIndex:UInt) {
        if hasProcessedImage {
            imageFramebuffer.lock()
            target.newFramebufferAvailable(imageFramebuffer, fromSourceIndex:atIndex)
        }
    }
    
    override func renderFrame() {
        renderFramebuffer = sharedImageProcessingContext.framebufferCache.requestFramebufferWithProperties(.portrait, size:sizeOfInitialStageBasedOnFramebuffer(inputFramebuffers[0]!), stencil:mask != nil)
        
        let textureProperties = initialTextureProperties()
        configureFramebufferSpecificUniforms(inputFramebuffers[0]!)
        
        renderFramebuffer.activateFramebufferForRendering()
        clearFramebufferWithColor(backgroundColor)
        if let maskFramebuffer = maskFramebuffer {
            if drawUnmodifiedImageOutsideOfMask {
                renderQuadWithShader(sharedImageProcessingContext.passthroughShader, uniformSettings:nil, vertices:standardImageVertices, inputTextures:textureProperties)
            }
            renderStencilMaskFromFramebuffer(maskFramebuffer)
            internalRenderFunction(inputFramebuffers[0]!, textureProperties:textureProperties)
            disableStencil()
        } else {
            internalRenderFunction(inputFramebuffers[0]!, textureProperties:textureProperties)
        }
    }
}
