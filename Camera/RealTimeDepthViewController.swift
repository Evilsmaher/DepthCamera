//
//  RealtimeDepthViewController.swift
//
//  Created by Bradley French on 7/3/19.
//  Copyright © 2019 Bradley French. All rights reserved.
//

import UIKit
import MetalKit
import AVFoundation

public class RealtimeDepthMaskViewController: UIViewController {
    
    @IBOutlet weak var mtkView: MTKView!
    @IBOutlet weak var segmentedCtl: UISegmentedControl!
    @IBOutlet weak var cameraButon: UIButton!
    @IBOutlet weak var imageView1: UIImageView!
    @IBOutlet weak var imageView2: UIImageView!
    
    private var videoCapture: VideoCapture!
    private var currentCameraType: CameraType = .front(true)
    private let serialQueue = DispatchQueue(label: "com.myQueue.queue")
    private let imageQueue = DispatchQueue(label: "com.imageQueue.queue", qos: .utility)
    private var currentCaptureSize: CGSize = CGSize.zero
    private var currentCaptureMode: CameraMode = .photo
    
    private var filter = true
    private var binarize = true
    private var gamma = true
    
    private var renderer: MetalRenderer!
    
    private var bgUIImages: [UIImage] = []
    private var bgImages: [CIImage] = []
    private var bgImageIndex: Int = 0
    private var videoImage: CIImage?
    private var maskImage: CIImage?
    private var finalImage: CIImage!
    private var completionHandler:((_ image: UIImage?, _ videoUrl: URL?) -> Void)!
    //    private var context:CGContext!
    private var maskedContext:CGContext!
    
    private var videoCreator: VideoCreator!
    private var isRecording:Bool = false
    //private var lastDepthBuffer:CVPixelBuffer!
    
    var images:[CIImage] = []
    var maskedImages:[CIImage] = []
    //    var finalBuffers:[CVPixelBuffer] = []
    
    public static func createRealTimeDepthCameraVC(completionHandler:@escaping ((_ image: UIImage?, _ videoUrl: URL?) -> Void), backgroundImages:[UIImage]?) -> RealtimeDepthMaskViewController{
        let newViewController = UIStoryboard(name: "DepthCamera", bundle: Bundle(for: RealtimeDepthMaskViewController.self)).instantiateViewController(withIdentifier: "DepthCamera") as! RealtimeDepthMaskViewController
        newViewController.completionHandler = completionHandler
        if(backgroundImages != nil) {
            for image in backgroundImages! {
                newViewController.bgUIImages.append(image)
            }
        }
        return newViewController
    }
    
    //Require others to use the init so the button has a selector and any optional images
    
    internal required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
    }
    
    public override func viewDidLoad() {
        super.viewDidLoad()
        #if targetEnvironment(simulator)
        print("Cannot use simulator")
        #else
        
        let device = MTLCreateSystemDefaultDevice()!
        mtkView.device = device
        mtkView.backgroundColor = UIColor.clear
        mtkView.delegate = self
        
        renderer = MetalRenderer(metalDevice: device, renderDestination: mtkView)
        
        videoCapture = VideoCapture(cameraMode: self.currentCaptureMode, cameraType: currentCameraType,
                                    preferredSpec: nil,
                                    previewContainer: nil)
        
        videoCapture.syncedDataBufferHandler = { [weak self] videoPixelBuffer, depthDataBuffer, face in
            guard let self = self else { return }
            
            self.videoImage = CIImage(cvPixelBuffer: videoPixelBuffer)
            //self.videoImage = CIImage(cvPixelBuffer: self.videoCapture.buffer)
            
            let videoWidth = CVPixelBufferGetWidth(videoPixelBuffer)
            let videoHeight = CVPixelBufferGetHeight(videoPixelBuffer)
            
            let captureSize = CGSize(width: videoWidth, height: videoHeight)
            guard self.currentCaptureSize == captureSize else {
                // Update the images' size
                self.bgImages.removeAll()
                self.bgImages = self.bgUIImages.map {
                    return $0.adjustedCIImage(targetSize: captureSize)!
                }
                self.currentCaptureSize = captureSize
                return
            }
            
            DispatchQueue.main.async(execute: {
                let binarize = self.binarize
                let gamma = self.gamma
                self.serialQueue.async {
                    //guard let depthPixelBuffer = depthData?.depthDataMap else { return }
                    self.processBuffer(videoPixelBuffer: videoPixelBuffer, depthPixelBuffer: depthDataBuffer, face: face, shouldBinarize: binarize, shouldGamma: gamma)
                }
            })
        }
        
        videoCapture.setDepthFilterEnabled(self.filter)
        
        //Add button action
        self.cameraButon.addTarget(self, action: #selector(buttonClicked), for: .touchUpInside)
        
        #endif
    }
    
    @objc func buttonClicked(sender: UIButton) {
        if(currentCaptureMode == .photo) {
            if let finalImage = self.finalImage {
                //xlet ciimage:CIImage = CIImage(cvPixelBuffer: self.lastDepthBuffer)
                let ciimage = finalImage
                let cgimage:CGImage = ciimage.convertCIImageToCGImage()
                //                let image:UIImage = UIImage(cgImage: cgimage)
                //                let regImage:UIImage = UIImage(ciImage: finalImage)
                //                let ratio = regImage.size.width/image.size.width
                //                let sizedImage = resizeImage(image: image, toScale: ratio)
                //                print(image.size, regImage.size, sizedImage.size)
                
                let transparentImage = processPixels(ciimage, image: UIImage(ciImage: ciimage))
                self.completionHandler(transparentImage!, nil)
                //                self.completionHandler(UIImage(ciImage: finalImage), nil)
            }
        }
        else if(currentCaptureMode == .video){
            if(!self.isRecording) {
                self.isRecording = true
            }
            else {
                self.videoCapture.stopCapture()
                let image = UIImage(ciImage: self.images[0])
                self.videoCreator = VideoCreator(fps: 1, width: image.size.width, height: image.size.height)
                
                var newImages:[UIImage] = []
                for i in 0 ..< self.images.count {
                    let ciimage = self.images[i]
                    //                    let cgimage:CGImage = ciimage.convertCIImageToCGImage()
                    //                    let image:UIImage = UIImage(cgImage: cgimage)
                    //                    let regImage:UIImage = UIImage(ciImage: ciimage)
                    //                    let ratio = regImage.size.width/image.size.width
                    //                    let sizedImage = resizeImage(image: image, toScale: ratio)
                    //                    print(image.size, regImage.size, sizedImage.size)
                    
                    let transparentImage = resizeImage(image: processPixels(ciimage, image: UIImage(ciImage: ciimage))!, toScale: 0.1)
                    newImages.append(transparentImage)
                }
                
                self.videoCreator.startCreatingVideo(images: newImages) {
                    self.completionHandler(nil, self.videoCreator.getURL())
                }
            }
        }
    }
    
    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard let videoCapture = videoCapture else {return}
        videoCapture.startCapture()
    }
    
    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let videoCapture = videoCapture else {return}
        videoCapture.resizePreview()
    }
    
    public override func viewWillDisappear(_ animated: Bool) {
        guard let videoCapture = videoCapture else {return}
        videoCapture.imageBufferHandler = nil
        videoCapture.stopCapture()
        mtkView.delegate = nil
        super.viewWillDisappear(animated)
    }
    
    @IBAction func cameraModeBtnTapped(_ sender: UIButton) {
        switch currentCaptureMode {
        case .photo:
            currentCaptureMode = .video
            sender.setTitle("Current: Video", for: .normal)
        case .video:
            currentCaptureMode = .photo
            sender.setTitle("Current: Photo", for: .normal)
        }
        self.videoCapture.setCameraMode(cameraMode: currentCaptureMode)
    }
    
    @IBAction func cameraSwitchBtnTapped(_ sender: UIButton) {
        switch currentCameraType {
        case .back:
            currentCameraType = .front(true)
        case .front:
            currentCameraType = .back(true)
        }
        bgImageIndex = 0
        videoCapture.changeCamera(with: currentCameraType)
    }
    
    func printTimeElapsedWhenRunningCode(title:String, operation:()->()) {
        let startTime = CFAbsoluteTimeGetCurrent()
        operation()
        let timeElapsed = CFAbsoluteTimeGetCurrent() - startTime
        print("Time elapsed for \(title): \(timeElapsed) s.")
    }
    
    func timeElapsedInSecondsWhenRunningCode(operation: ()->()) -> Double {
        let startTime = CFAbsoluteTimeGetCurrent()
        operation()
        let timeElapsed = CFAbsoluteTimeGetCurrent() - startTime
        return Double(timeElapsed)
    }
}

extension RealtimeDepthMaskViewController {
    private func readDepth(from depthPixelBuffer: CVPixelBuffer, at position: CGPoint, scaleFactor: CGFloat) -> Float {
        let pixelX = Int((position.x * scaleFactor).rounded())
        let pixelY = Int((position.y * scaleFactor).rounded())
        
        CVPixelBufferLockBaseAddress(depthPixelBuffer, .readOnly)
        
        let rowData = CVPixelBufferGetBaseAddress(depthPixelBuffer)! + pixelY * CVPixelBufferGetBytesPerRow(depthPixelBuffer)
        let faceCenterDepth = rowData.assumingMemoryBound(to: Float32.self)[pixelX]
        CVPixelBufferUnlockBaseAddress(depthPixelBuffer, .readOnly)
        
        return faceCenterDepth
    }
    
    func processBuffer(videoPixelBuffer: CVPixelBuffer, depthPixelBuffer: CVPixelBuffer, face: AVMetadataObject?, shouldBinarize: Bool, shouldGamma: Bool) {
        let videoWidth = CVPixelBufferGetWidth(videoPixelBuffer)
        let depthWidth = CVPixelBufferGetWidth(depthPixelBuffer)
        
        var depthCutOff: Float = 1.0
        if let face = face {
            let faceCenter = CGPoint(x: face.bounds.midX, y: face.bounds.midY)
            let scaleFactor = CGFloat(depthWidth) / CGFloat(videoWidth)
            let faceCenterDepth = readDepth(from: depthPixelBuffer, at: faceCenter, scaleFactor: scaleFactor)
            depthCutOff = faceCenterDepth + 0.25
        }
        
        // Convert depth map in-place: every pixel above cutoff is converted to 1. otherwise it's 0
        if shouldBinarize {
            let _ = depthPixelBuffer.binarize(cutOff: depthCutOff, ciimage: self.videoImage!)
        }
        
        // Create the mask from that pixel buffer.
        let depthImage = CIImage(cvPixelBuffer: depthPixelBuffer, options: [:])
        
        // Smooth edges to create an alpha matte, then upscale it to the RGB resolution.
        let alphaUpscaleFactor = Float(CVPixelBufferGetWidth(videoPixelBuffer)) / Float(depthWidth)
        let processedDepth: CIImage
        processedDepth = shouldGamma ? depthImage.applyBlurAndGamma() : depthImage
        
        self.maskImage = processedDepth.applyingFilter("CIBicubicScaleTransform", parameters: ["inputScale": alphaUpscaleFactor])
    }
}

extension CVPixelBuffer {
    
    func binarize(cutOff: Float, ciimage: CIImage) -> CVPixelBuffer {
        CVPixelBufferLockBaseAddress(self, CVPixelBufferLockFlags(rawValue: 0))
        let widthCI = CVPixelBufferGetWidth(self)
        let heightCI = CVPixelBufferGetHeight(self)
        for yMap in 0 ..< heightCI {
            let rowData = CVPixelBufferGetBaseAddress(self)! + yMap * CVPixelBufferGetBytesPerRow(self)
            let data = UnsafeMutableBufferPointer<Float32>(start: rowData.assumingMemoryBound(to: Float32.self), count: widthCI)
            for index in 0 ..< widthCI {
                //For Screen
                let depth = data[index]
                if depth.isNaN {
                    data[index] = 1.0
                } else if depth <= cutOff {
                    data[index] = 1.0
                } else {
                    data[index] = 0.0
                }
            }
        }
        
        CVPixelBufferUnlockBaseAddress(self, CVPixelBufferLockFlags(rawValue: 0))
        
        return self
    }
}

extension CIImage {
    func applyBlurAndGamma() -> CIImage {
        return clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": 3.0])
            .applyingFilter("CIGammaAdjust", parameters: ["inputPower": 0.5])
            .cropped(to: extent)
    }
}

extension RealtimeDepthMaskViewController: MTKViewDelegate {
    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
    }
    
    public func draw(in view: MTKView) {
        switch segmentedCtl.selectedSegmentIndex {
        case 0:
            // original
            if let image = videoImage {
                renderer.update(with: image)
                self.finalImage = image
            }
        case 1:
            // blended
            guard let image = videoImage, let maskImage = maskImage else { return }
            
            var parameters = ["inputMaskImage": maskImage]
            
            if(!self.bgImages.isEmpty) {
                let index = self.bgImageIndex
                let bgImage = self.bgImages[index]
                parameters["inputBackgroundImage"] = bgImage
                self.bgImageIndex = index == self.bgImages.count - 1 ? 0 : index + 1
            }
            
            let outputImage = image.applyingFilter("CIBlendWithMask", parameters: parameters)
            renderer.update(with: outputImage)
            self.finalImage = outputImage
        default:
            return
        }
        if(self.isRecording) {
            //            let ciimage = CIImage(cvPixelBuffer: self.videoCapture.buffer)
            let ciimage = self.finalImage!
            let maskedImage = self.maskImage!
            let image = UIImage(ciImage: ciimage)
            
            if(image.size.width != 0) {
                //                let newImage = resizeImage(image: image, toScale: 0.1)
                self.images.append(ciimage)
                self.maskedImages.append(maskedImage)
                //                self.finalBuffers.append(self.lastDepthBuffer)
                self.imageView1.image = image
                self.imageView2.image = UIImage(ciImage: self.finalImage)
            }
        }
    }
    
    private func resizeImage(image: UIImage, toScale: CGFloat) -> UIImage {
        return autoreleasepool { () -> UIImage in
            
            let size = image.size.applying(CGAffineTransform(scaleX: toScale, y: toScale))
            let newSize = CGSize(width: size.width, height: size.height)
            let hasAlpha = false
            
            let scale:CGFloat = 0.0
            UIGraphicsBeginImageContextWithOptions(newSize, !hasAlpha, scale)
            image.draw(in: CGRect(origin: .zero, size: newSize))
            
            let newImage = UIGraphicsGetImageFromCurrentImageContext() //Leaked
            UIGraphicsEndImageContext()
            
            return newImage!
        }
    }
    func processPixels(_ ciimage: CIImage, image:UIImage) -> UIImage? {
        let inputCGImage = ciimage.convertCIImageToCGImage()!
        
        let colorSpace       = CGColorSpaceCreateDeviceRGB()
        let width            = inputCGImage.width
        let height           = inputCGImage.height
        let bytesPerPixel    = 4
        let bitsPerComponent = 8
        let bytesPerRow      = bytesPerPixel * width
        let bitmapInfo       = RGBA32.bitmapInfo
        
        
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: bitsPerComponent, bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: bitmapInfo) else {
            print("Couldn't create CGContext")
            return nil
        }
        
        context.draw(inputCGImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        guard let buffer = context.data else {
            print("unable to get context data")
            return nil
        }
        
        let pixelBuffer = buffer.bindMemory(to: RGBA32.self, capacity: width * height)
        
        
        for row in 0 ..< Int(height) {
            for column in 0 ..< Int(width) {
                let offset = row * width + column
                if(pixelBuffer[offset] == RGBA32.init(red: 0, green: 0, blue: 0, alpha: 0)) {
                    //                    pixelBuffer[offset] = RGBA32.init(red: 255, green: 0, blue: 0, alpha: 255)
                    //  pixelBuffer[offset] = RGBA32.init(red: 0, green: 0, blue: 0, alpha: 0)
                }
            }
        }
        
        
        
        let outputCGImage = context.makeImage()!
        let outputImage = UIImage(cgImage: outputCGImage, scale: image.scale, orientation: image.imageOrientation)
        
        return outputImage
    }
}

struct RGBA32: Equatable {
    private var color: UInt32
    
    var redComponent: UInt8 {
        return UInt8((color >> 24) & 255)
    }
    
    var greenComponent: UInt8 {
        return UInt8((color >> 16) & 255)
    }
    
    var blueComponent: UInt8 {
        return UInt8((color >> 8) & 255)
    }
    
    var alphaComponent: UInt8 {
        return UInt8((color >> 0) & 255)
    }
    
    init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
        let red   = UInt32(red)
        let green = UInt32(green)
        let blue  = UInt32(blue)
        let alpha = UInt32(alpha)
        color = (red << 24) | (green << 16) | (blue << 8) | (alpha << 0)
    }
    
    static let red     = RGBA32(red: 255, green: 0,   blue: 0,   alpha: 255)
    static let green   = RGBA32(red: 0,   green: 255, blue: 0,   alpha: 255)
    static let blue    = RGBA32(red: 0,   green: 0,   blue: 255, alpha: 255)
    static let white   = RGBA32(red: 255, green: 255, blue: 255, alpha: 255)
    static let black   = RGBA32(red: 0,   green: 0,   blue: 0,   alpha: 255)
    static let magenta = RGBA32(red: 255, green: 0,   blue: 255, alpha: 255)
    static let yellow  = RGBA32(red: 255, green: 255, blue: 0,   alpha: 255)
    static let cyan    = RGBA32(red: 0,   green: 255, blue: 255, alpha: 255)
    
    static let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    
    static func ==(lhs: RGBA32, rhs: RGBA32) -> Bool {
        return lhs.color == rhs.color
    }
}

extension CIImage {
    func convertCIImageToCGImage() -> CGImage! {
        let context = CIContext(options: nil)
        return context.createCGImage(self, from: self.extent)
    }
}

extension RangeReplaceableCollection where Element: Hashable {
    var orderedSet: Self {
        var set = Set<Element>()
        return filter { set.insert($0).inserted }
    }
    mutating func removeDuplicates() {
        var set = Set<Element>()
        removeAll { !set.insert($0).inserted }
    }
}

extension UIImage {
    /// Get the pixel color at a point in the image
    func pixelColor(atLocation point: CGPoint) -> UIColor? {
        guard let cgImage = cgImage, let pixelData = cgImage.dataProvider?.data else { print("Error getting pixel color"); return nil }
        
        let data: UnsafePointer<UInt8> = CFDataGetBytePtr(pixelData)
        
        let bytesPerPixel = cgImage.bitsPerPixel / 8
        
        let pixelInfo: Int = ((cgImage.bytesPerRow * Int(point.y)) + (Int(point.x) * bytesPerPixel))
        
        let b = CGFloat(data[pixelInfo]) / CGFloat(255.0)
        let g = CGFloat(data[pixelInfo+1]) / CGFloat(255.0)
        let r = CGFloat(data[pixelInfo+2]) / CGFloat(255.0)
        let a = CGFloat(data[pixelInfo+3]) / CGFloat(255.0)
        
        return UIColor(red: r, green: g, blue: b, alpha: a)
    }
}
