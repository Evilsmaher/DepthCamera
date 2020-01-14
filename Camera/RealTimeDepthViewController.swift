//
//  RealtimeDepthViewController.swift
//
//  Created by Bradley French on 7/3/19.
//  Copyright © 2019 Bradley French. All rights reserved.
//

import UIKit
import MetalKit
import AVFoundation
import CoreImage
import Accelerate
import RecordButton

public class RealtimeDepthMaskViewController: UIViewController {
    
    @IBOutlet weak var mtkView: MTKView!
    @IBOutlet weak var segmentedCtl: UISegmentedControl!
    @IBOutlet weak var cameraButon: RecordButton!
    @IBOutlet weak var cameraLabel: UILabel!
    @IBOutlet weak var switchCameraButton: UIButton!
    
    private var timer: Timer!
    
    private var videoCapture: VideoCapture!
    private var currentCameraType: CameraType = .front(true)
    private let serialQueue = DispatchQueue(label: "com.myQueue.queue")
    private let imageQueue = DispatchQueue(label: "com.imageQueue.queue", qos: .utility)
    private var imageQueueIsEmpty = false
    
    private let dispatchGroup = DispatchGroup()
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
    private var curAudioSnip: CMSampleBuffer!
    private var completionHandler:((_ image: UIImage?, _ videoUrl: URL?, _ is3D:Bool?) -> Void)!
    
    private var videoCreator: VideoCreator!
    private var isRecording:Bool = false
    private var initTime:CFAbsoluteTime!
    private static var filter:CIFilter!
    
    private var maxVideoTime:CGFloat = CGFloat(60)
    private var progress:CGFloat = CGFloat(0)
    
    public static func createRealTimeDepthCameraVC(imageOrVideoCaptureMode: CameraMode, completionHandler:@escaping ((_ image: UIImage?, _ videoUrl: URL?, _ is3D:Bool?) -> Void), backgroundImages:[UIImage]?) -> RealtimeDepthMaskViewController {
        let newViewController = UIStoryboard(name: "DepthCamera", bundle: Bundle(for: RealtimeDepthMaskViewController.self)).instantiateViewController(withIdentifier: "DepthCamera") as! RealtimeDepthMaskViewController
        newViewController.completionHandler = completionHandler
        if(backgroundImages != nil) {
            for image in backgroundImages! {
                newViewController.bgUIImages.append(image)
            }
        }
        newViewController.currentCaptureMode = imageOrVideoCaptureMode
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
        mtkView.framebufferOnly = false
        mtkView.delegate = self
        
        renderer = MetalRenderer(metalDevice: device, renderDestination: mtkView)
        
        videoCapture = VideoCapture(cameraMode: self.currentCaptureMode, cameraType: currentCameraType,
                                    preferredSpec: nil,
                                    previewContainer: nil)
        
        videoCapture.syncedDataBufferHandler = { [weak self] videoPixelBuffer, depthDataBuffer, face in
            guard let self = self else { return }
//            if(self.isRecording) {
//                let elapsed = CFAbsoluteTimeGetCurrent() - self.initTime
//                if(elapsed > 60) {
//                    self.isRecording = false
//                    self.timer.invalidate()
//                }
//            }
            self.videoImage = CIImage(cvPixelBuffer: videoPixelBuffer)
            
            let videoWidth = CVPixelBufferGetWidth(videoPixelBuffer)
            let videoHeight = CVPixelBufferGetHeight(videoPixelBuffer)
            
            let captureSize = CGSize(width: videoWidth, height: videoHeight)
//            print("Size: \(captureSize)")
            
            //1) Only need to apply backgroundImages if it is in 3D
            //2) Only need to get maskedImage if it is 3D
            if(self.segmentedCtl.selectedSegmentIndex == 1) {
//                print("Segment 1")
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
//                        let x = CFAbsoluteTimeGetCurrent()m
                        self.processBuffer(videoPixelBuffer: videoPixelBuffer, depthPixelBuffer: depthDataBuffer, face: face, shouldBinarize: binarize, shouldGamma: gamma)
//                        print(CFAbsoluteTimeGetCurrent() - x)
                    }
                })
            }
            else {
//                print("Segment 0")
            }
        }
        
        videoCapture.audioBufferHandler = { [weak self] (audio, time) in
//            print("Setting Audio Snip")
            self!.curAudioSnip = audio
            if(self!.isRecording) {
                self!.videoCreator.addAudio(audio: audio, time: time)
            }
        }
        
        videoCapture.setDepthFilterEnabled(self.filter)
        
        //Add button action
        self.cameraButon.addTarget(self, action: #selector(buttonClicked), for: .touchUpInside)
        
        #endif
    }
    
    func getAudioSettingsFromVideoCapture() -> [String:Any]? {
        return videoCapture!.audioSettings as? [String : Any]
    }
    
    @objc func buttonClicked(sender: UIButton) {
        self.segmentedCtl.isUserInteractionEnabled = false
        if(currentCaptureMode == .photo) {
            if let finalImage = self.finalImage {
                let transparentImage = processPixels(finalImage, image: UIImage(ciImage: finalImage))
                self.completionHandler(transparentImage, nil, self.segmentedCtl.selectedSegmentIndex == 0)
            }
        }
        else if(currentCaptureMode == .video){
            self.timer = Timer.scheduledTimer(timeInterval: 0.05, target: self, selector: #selector(updateTimer), userInfo: nil, repeats: true)
            sender.backgroundColor = sender.backgroundColor == UIColor.red ? UIColor(displayP3Red: 0.238155, green: 0.406666, blue: 0.930306, alpha: 0.847059) : UIColor.red
            if(!self.isRecording) {
                self.switchCameraButton.isHidden = true
                self.switchCameraButton.isUserInteractionEnabled = false
                let image = UIImage(ciImage: self.finalImage!)
                self.videoCreator = VideoCreator(fps: self.videoCapture.frameRate, width: image.size.width, height: image.size.height, audioSettings: AVCaptureAudioDataOutput().recommendedAudioSettingsForAssetWriter(writingTo: .mp4) as? [String:Any])
                initTime = CFAbsoluteTimeGetCurrent()
                self.isRecording = true
                //We save the current segment selection incase user changes it later - like right at end before the video is done -- easier if we just save the current selection and push that in later
                let currentSelection = self.segmentedCtl.selectedSegmentIndex
                self.videoCreator.startCreatingVideo(initialBuffer: self.curAudioSnip) {
                    //image, videoURL, is3D
                    self.completionHandler(nil, self.videoCreator.getURL(), currentSelection == 1)
                }
            }
            else {
                timer.invalidate()
                self.switchCameraButton.isHidden = false
                self.switchCameraButton.isUserInteractionEnabled = true
                self.isRecording = false
                self.videoCapture.stopCapture()
                //I do a check here incase because the queue might be empty for 2D (but probably won't be for 3D) but since the queue is empty, the DispatchGroup.notify will never get called
                if(self.imageQueueIsEmpty) {
                    print("Done Writing")
                    self.videoCreator.finishWriting()
                    let elapsed = CFAbsoluteTimeGetCurrent() - self.initTime
                    print("Your video should be about \(elapsed) seconds")
                }
            }
        }
    }
    
    @objc func updateTimer() {
        progress = progress + (CGFloat(0.05) / maxDuration)
        self.cameraButon.setProgress(progress)
        if(progress >= 1) {
            timer.invalidate()
            self.isRecording = false
        }
    }
    
    func videoSnapshot(url: URL, time:CMTime) -> UIImage? {
        
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        
        let timestamp = time
        
        do {
            let imageRef = try generator.copyCGImage(at: timestamp, actualTime: nil)
            return UIImage(cgImage: imageRef)
        }
        catch let error as NSError
        {
            print("Image generation failed with error \(error)")
            return nil
        }
    }
    
    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        self.cameraLabel.text = self.currentCaptureMode == .photo ? "Photo" : "Video"
        guard let videoCapture = videoCapture else {return}
        videoCapture.startCapture()
        mtkView.delegate = self
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
        
        let initDepth = CFAbsoluteTimeGetCurrent()
        var depthCutOff: Float = 1.0
        if let face = face {
            let faceCenter = CGPoint(x: face.bounds.midX, y: face.bounds.midY)
            let scaleFactor = CGFloat(depthWidth) / CGFloat(videoWidth)
            let faceCenterDepth = readDepth(from: depthPixelBuffer, at: faceCenter, scaleFactor: scaleFactor)
            depthCutOff = faceCenterDepth + 0.25
        }
//        print("Time Depth: \(CFAbsoluteTimeGetCurrent() - initDepth)")
        
        // Convert depth map in-place: every pixel above cutoff is converted to 1. otherwise it's 0
        if shouldBinarize {
            let initBinarize = CFAbsoluteTimeGetCurrent()
            let _ = depthPixelBuffer.binarize(cutOff: depthCutOff, ciimage: self.videoImage!)
//            print("Time Binarize: \(CFAbsoluteTimeGetCurrent() - initBinarize)")
        }
        
        // Create the mask from that pixel buffer.
        let depthImage = CIImage(cvPixelBuffer: depthPixelBuffer, options: [:])
        
        // Smooth edges to create an alpha matte, then upscale it to the RGB resolution.
        let alphaUpscaleFactor = Float(CVPixelBufferGetWidth(videoPixelBuffer)) / Float(depthWidth)
        let processedDepth: CIImage
        processedDepth = shouldGamma ? depthImage.applyBlurAndGamma() : depthImage
        
        let timeFilter = CFAbsoluteTimeGetCurrent()
        self.maskImage = processedDepth.applyingFilter("CIBicubicScaleTransform", parameters: ["inputScale": alphaUpscaleFactor])
//        print("Time Filter: \(CFAbsoluteTimeGetCurrent() - timeFilter)")
    }
    
    public static func createFilter() {
        RealtimeDepthMaskViewController.filter = chromaKeyFilter(fromHue: 114/360, toHue: 126/360)!
    }
    
    public static func filteredImage(ciimage: CIImage) -> CIImage? {
        RealtimeDepthMaskViewController.filter.setValue(ciimage, forKey: kCIInputImageKey)
        return RealtimeDepthMaskViewController.filter.outputImage
    }
    
    static func chromaKeyFilter(fromHue: CGFloat, toHue: CGFloat) -> CIFilter?
    {
        // 1
        let size = 64
        var cubeRGB = [Float]()
        
        // 2
        for z in 0 ..< size {
            let blue = CGFloat(z) / CGFloat(size-1)
            for y in 0 ..< size {
                let green = CGFloat(y) / CGFloat(size-1)
                for x in 0 ..< size {
                    let red = CGFloat(x) / CGFloat(size-1)
                    
                    // 3
                    let hue = getHue(red: red, green: green, blue: blue)
                    let alpha: CGFloat = (hue >= fromHue && hue <= toHue) ? 0: 1
                    
                    // 4
                    cubeRGB.append(Float(red * alpha))
                    cubeRGB.append(Float(green * alpha))
                    cubeRGB.append(Float(blue * alpha))
                    cubeRGB.append(Float(alpha))
                }
            }
        }
        
        let data = Data(buffer: UnsafeBufferPointer(start: &cubeRGB, count: cubeRGB.count))
        
        // 5
        let colorCubeFilter = CIFilter(name: "CIColorCube", parameters: ["inputCubeDimension": size, "inputCubeData": data])
        return colorCubeFilter
    }
    
    static func getHue(red: CGFloat, green: CGFloat, blue: CGFloat) -> CGFloat {
        let color = UIColor(red: red, green: green, blue: blue, alpha: 1)
        var hue: CGFloat = 0
        color.getHue(&hue, saturation: nil, brightness: nil, alpha: nil)
        return hue
    }
    
    static func getAudioFromURL(url: URL, completionHandlerPerBuffer: @escaping ((_ buffer:CMSampleBuffer) -> Void)) {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: NSNumber(value: true as Bool)])
        
        guard let assetTrack = asset.tracks(withMediaType: AVMediaType.audio).first else {
            fatalError("Couldn't load AVAssetTrack")
        }
        
        
        guard let reader = try? AVAssetReader(asset: asset)
            else {
                fatalError("Couldn't initialize the AVAssetReader")
        }
        reader.timeRange = CMTimeRange(start: .zero, duration: asset.duration)
        
        let outputSettingsDict: [String : Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let readerOutput = AVAssetReaderTrackOutput(track: assetTrack,
                                                    outputSettings: outputSettingsDict)
        readerOutput.alwaysCopiesSampleData = false
        reader.add(readerOutput)
        
        while reader.status == .reading {
            guard let readSampleBuffer = readerOutput.copyNextSampleBuffer() else { break }
            completionHandlerPerBuffer(readSampleBuffer)
            
        }
    }
    
    //Removes the color from the AVAsset
    public static func create2DVideo(asset: AVAsset, completionHandler: @escaping (_ asset: AVAsset) -> Void) {
        let url = (asset as? AVURLAsset)!.url
        let snapshot = url.videoSnapshot()
        guard let image = snapshot else { return }
        let fps = Int32(asset.tracks(withMediaType: .video)[0].nominalFrameRate)
//        print("FPS: \(fps)")
        let writer = VideoCreator(fps: Int32(fps), width: image.size.width, height: image.size.height, audioSettings: nil)
        
        let timeScale = asset.duration.timescale
        let timeValue = asset.duration.value
        let frameTime = 1/Double(fps) * Double(timeScale)
        let numberOfImages = Int(Double(timeValue)/Double(frameTime))
        let queue = DispatchQueue(label: "com.queue.queue", qos: .utility)
        let composition = AVVideoComposition(asset: asset) { (request) in
            let source = request.sourceImage.clampedToExtent()
            let filteredImage = RealtimeDepthMaskViewController.filteredImage(ciimage: source)!.clamped(to: source.extent)
            request.finish(with: filteredImage, context: nil)
        }
        
        var i = 0
        RealtimeDepthMaskViewController.getAudioFromURL(url: url) { (buffer) in
            writer.addAudio(audio: buffer, time: .zero)
            i == 0 ? writer.startCreatingVideo(initialBuffer: buffer, completion: {}) : nil
            i += 1
        }
        
        let group = DispatchGroup()
        for i in 0..<numberOfImages {
            group.enter()
            autoreleasepool {
                let time = CMTime(seconds: Double(Double(i) * frameTime / Double(timeScale)), preferredTimescale: timeScale)
                let image = url.videoSnapshot(time: time, composition: composition)
                queue.async {
                    
                    writer.addImageAndAudio(image: image!, audio: nil, time: time.seconds)
                    group.leave()
                }
            }
        }
        group.notify(queue: queue) {
            writer.finishWriting()
            let url = writer.getURL()
            
            //Now create exporter to add audio then do completion handler
            completionHandler(AVAsset(url: url))
            
        }
    }
    
    public static func get3DChromaKey() -> ChromaKeyMaterial {
        return ChromaKeyMaterial()
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

extension AVAsset {
    
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
    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    
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
            guard let image = self.videoImage, let maskImage = self.maskImage else { return }
            
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
//        print(UIImage(ciImage: self.finalImage).size)
        
        if(self.isRecording) {
            let time = CFAbsoluteTimeGetCurrent()
            let presTime = time - self.initTime
//            print(presTime)
            self.dispatchGroup.enter()
            self.imageQueueIsEmpty = false
            autoreleasepool { [weak self] in
                //3D video
                if(self!.segmentedCtl.selectedSegmentIndex == 1) {
                    let regImage = self!.resizeImage(image: UIImage(ciImage: self!.videoImage!), toScale: 0.25)
                    let maskedImage = self!.resizeImage(image: UIImage(ciImage: self!.maskImage!), toScale: 0.25)
                    let audioBuffer = self!.curAudioSnip!
                    print("Reg Image: \(regImage.size)")
                    print("Masked Image: \(maskedImage.size)")
                    self!.imageQueue.async { [weak self] in
                        autoreleasepool { [weak self] in
                            guard let self = self else { return }
                            guard let correctCIImage = self.recreateDepthMaskFromTwoUIImages(regImage: regImage, maskImage: maskedImage) else { return }
                            let transparentImage = self.processPixels(correctCIImage, image: UIImage(ciImage: correctCIImage), fromColor: RGBA32.init(red: 0, green: 0, blue: 0, alpha: 0), toColor: RGBA32.green)!
                            print(transparentImage.size)
                            self.videoCreator.addImageAndAudio(image: transparentImage, audio: audioBuffer, time: presTime)
                            self.dispatchGroup.leave()
                        }
                    }
                }
                //2D video
                else {
                    let regImage = self!.resizeImage(image: UIImage(ciImage: self!.videoImage!), toScale: 0.1)
                    let audioBuffer = self!.curAudioSnip!
                    self!.imageQueue.async { [weak self] in
                        autoreleasepool { [weak self] in
                            guard let self = self else { return }
                            self.videoCreator.addImageAndAudio(image: regImage, audio: audioBuffer, time: presTime)
                            self.dispatchGroup.leave()
                        }
                    }
                }
            }
            //I do a check here incase because the done button might be clicked but the video processing is still continuing in the background. Need to make sure we wait until all data is ready.
            self.dispatchGroup.notify(queue: self.imageQueue) {
                self.imageQueueIsEmpty = true
                if(!self.isRecording) {
                    print("Done Writing")
                    self.videoCreator.finishWriting()
                    let elapsed = CFAbsoluteTimeGetCurrent() - self.initTime
                    print("Your video should be about \(elapsed) seconds")
                }
            }
        }
    }
    
    private func recreateDepthMaskFromTwoUIImages(regImage:UIImage, maskImage:UIImage) -> CIImage? {
        //Convert each to CIImage
        let regCIImage = CIImage(image: regImage)
        let maskImage = CIImage(image: maskImage)
        
        //Apply filters using backgrounds
        let filter = CIFilter(name: "CIBlendWithMask")
        filter!.setValue(maskImage, forKey: "inputMaskImage")
        filter!.setValue(regCIImage, forKey: "inputImage")
        
        //Get outputimage from filters
        return filter!.outputImage!
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
    
    //Get Clear Pixels
    func processPixels(_ ciimage: CIImage, image:UIImage, fromColor:RGBA32? = nil, toColor:RGBA32? = nil) -> UIImage? {
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
        
        if(toColor != nil && fromColor != nil) {
            guard let buffer = context.data else {
                print("unable to get context data")
                return nil
            }
            
            let pixelBuffer = buffer.bindMemory(to: RGBA32.self, capacity: width * height)
            
            for row in 0 ..< Int(height) {
                for column in 0 ..< Int(width) {
                    let offset = row * width + column
                    if pixelBuffer[offset] == fromColor! {
                        pixelBuffer[offset] = toColor!
                    }
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

extension URL {
    func videoSnapshot(time:CMTime? = nil, composition:AVVideoComposition? = nil) -> UIImage? {
        let asset = AVURLAsset(url: self)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.videoComposition = composition
        
        let timestamp = time == nil ? CMTime(seconds: 1, preferredTimescale: 60) : time
        
        do {
            let imageRef = try generator.copyCGImage(at: timestamp!, actualTime: nil)
            return UIImage(cgImage: imageRef)
        }
        catch let error as NSError
        {
            print("Image generation failed with error \(error)")
            return nil
        }
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

