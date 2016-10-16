//
//  ViewController.swift
//  ShaderOnVideoDemo
//
//  Created by Aleksei Pupyshev on 10/16/16.
//  Copyright © 2016 Phirotto. All rights reserved.
//

import UIKit
import GPUImage
import AVFoundation

class ViewController: UIViewController {
    @IBOutlet weak var filterView: RenderView!
    
    let cameraObject: Camera?
    var maskDynamicInput: MaskPictureInput?
    
    let maskBlendFilter = AlphaBlend()
    let fbSize = Size(width: 640, height: 480)
    let faceDetector = CIDetector(ofType: CIDetectorTypeFace, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyLow])
    var shouldDetectFaces = true
    lazy var maskGenerator: MaskGenerator = {
        let gen = MaskGenerator(size: self.fbSize)
        gen.lineWidth = 5
        return gen
    }()
    
    required init(coder aDecoder: NSCoder) {
        do {
            cameraObject = try Camera(sessionPreset:AVCaptureSessionPreset640x480, location:.frontFacing)
            cameraObject!.runBenchmark = true
        } catch {
            cameraObject = nil
            print("Couldn't initialize camera with error: \(error)")
        }
        super.init(coder: aDecoder)!
    }
    func configureView() {
        guard let cameraObject = cameraObject else {
            let errorAlertController = UIAlertController(title: NSLocalizedString("Error", comment: "Error"), message: "Couldn't initialize camera", preferredStyle: .alert)
            errorAlertController.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "OK"), style: .default, handler: nil))
            self.present(errorAlertController, animated: true, completion: nil)
            return
        }
        cameraObject.addTarget(maskBlendFilter)
        maskGenerator.addTarget(maskBlendFilter)
        maskBlendFilter.addTarget(filterView)
        cameraObject.delegate = self
        cameraObject.startCapture()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        self.configureView()
        // Do any additional setup after loading the view, typically from a nib.
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        if let cameraObject = cameraObject {
            cameraObject.stopCapture()
            cameraObject.removeAllTargets()
            maskDynamicInput?.removeAllTargets()
        }
        
        super.viewWillDisappear(animated)
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }

}

extension ViewController: CameraDelegate {
    func didCaptureBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard shouldDetectFaces else {
            maskGenerator.positionMask([]) // clear
            return
        }
        
        if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            let attachments = CMCopyDictionaryOfAttachments(kCFAllocatorDefault, sampleBuffer, CMAttachmentMode(kCMAttachmentMode_ShouldPropagate))!
            let img = CIImage(cvPixelBuffer: pixelBuffer, options: attachments as? [String: AnyObject])
            var lines = [Line]()
            for feature in (faceDetector?.features(in: img, options: [CIDetectorImageOrientation: 6]))! {
                if feature is CIFaceFeature {
                    let faceFeature = feature as! CIFaceFeature
                    lines = maskCoordinates([faceFeature.leftEyePosition, faceFeature.rightEyePosition])
                }
            }
            maskGenerator.positionMask(lines)
        }
    }
    
    func maskCoordinates(_ eyes: [CGPoint]) -> [Line] {
        
        let flip = CGAffineTransform(scaleX: 1, y: -1)
        let rotate = flip.rotated(by: CGFloat(-M_PI_2))
        let translate = rotate.translatedBy(x: -1, y: -1)
        let xform = translate.scaledBy(x: CGFloat(2/fbSize.width), y: CGFloat(2/fbSize.height))
        
        let leftEye = eyes[0]
        let rightEye = eyes[1]
        let leftEyeGL = leftEye.applying(xform)
        let rightEyeGL = rightEye.applying(xform)
        
        let le = Position(Float(leftEyeGL.x), Float(leftEyeGL.y))
        let re = Position(Float(rightEyeGL.x), Float(rightEyeGL.y))
        
        return [.segment(p1:le, p2:re)]
    }
}

