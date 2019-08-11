//
//  VideoCreator.swift
//  AKPickerView-Swift
//
//  Created by Bradley French on 7/16/19.
//

import UIKit

import AVFoundation
import UIKit
import Photos

@available(iOS 11.0, *)
public class VideoCreator: NSObject {
    
    private var settings:RenderSettings!
    private var imageAnimator:ImageAnimator!
    
    public override init() {
        self.settings = RenderSettings()
        self.imageAnimator = ImageAnimator(renderSettings: self.settings)
    }
    
    public convenience init(fps: Int32, width: CGFloat, height: CGFloat) {
        self.init()
        self.settings = RenderSettings(fps: fps, width: width, height: height)
        self.imageAnimator = ImageAnimator(renderSettings: self.settings)
    }
    
    public convenience init(width: CGFloat, height: CGFloat) {
        self.init()
        self.settings = RenderSettings(width: width, height: height)
        self.imageAnimator = ImageAnimator(renderSettings: self.settings)
    }
    
    func startCreatingVideo(images:[UIImage], completion: @escaping (() -> Void)) {
        self.setImages(images: images)
        self.imageAnimator.render {
            completion()
        }
    }
    
    private func setImages(images:[UIImage]) {
        self.imageAnimator.setImages(images: images)
    }
    
    func getURL() -> URL {
        return settings!.outputURL
    }
}


@available(iOS 11.0, *)
public struct RenderSettings {
    
    var width: CGFloat = 1280
    var height: CGFloat = 720
    var fps: Int32 = 2   // 2 frames per second
    var avCodecKey = AVVideoCodecType.h264
    var videoFilename = "video"
    var videoFilenameExt = "mov"
    
    init() { }
    
    init(width: CGFloat, height: CGFloat) {
        self.width = width
        self.height = height
    }
    
    init(fps: Int32) {
        self.fps = fps
    }
    
    init(fps: Int32, width: CGFloat, height: CGFloat) {
        self.fps = fps
        self.width = width
        self.height = height
    }
    
    var size: CGSize {
        return CGSize(width: width, height: height)
    }
    
    var outputURL: URL {
        // Use the CachesDirectory so the rendered video file sticks around as long as we need it to.
        // Using the CachesDirectory ensures the file won't be included in a backup of the app.
        let fileManager = FileManager.default
        if let tmpDirURL = try? fileManager.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true) {
            return tmpDirURL.appendingPathComponent(videoFilename).appendingPathExtension(videoFilenameExt)
        }
        fatalError("URLForDirectory() failed")
    }
}

@available(iOS 11.0, *)
public class ImageAnimator {
    
    // Apple suggests a timescale of 600 because it's a multiple of standard video rates 24, 25, 30, 60 fps etc.
    static let kTimescale: Int32 = 600
    
    let settings: RenderSettings
    let videoWriter: VideoWriter
    var images:[UIImage] = []
    
    var frameNum = 0
    
    class func removeFileAtURL(fileURL: URL) {
        do {
            try FileManager.default.removeItem(atPath: fileURL.path)
        }
        catch _ as NSError {
            // Assume file doesn't exist.
        }
    }
    
    init(renderSettings: RenderSettings) {
        settings = renderSettings
        videoWriter = VideoWriter(renderSettings: settings)
    }
    
    func setImages(images: [UIImage]) {
        self.images = images
    }
    
    func render(completion: @escaping ()->Void) {
        
        // The VideoWriter will fail if a file exists at the URL, so clear it out first.
        ImageAnimator.removeFileAtURL(fileURL: settings.outputURL)
        
        videoWriter.start()
        videoWriter.render(appendPixelBuffers: appendPixelBuffers) {
            //ImageAnimator.saveToLibrary(self.settings.outputURL)
            completion()
        }
        
    }
    
    // This is the callback function for VideoWriter.render()
    func appendPixelBuffers(writer: VideoWriter) -> Bool {
        
        let frameDuration = CMTimeMake(value: Int64(ImageAnimator.kTimescale / settings.fps), timescale: ImageAnimator.kTimescale)
        
        //Don't stop while images are NOT empty
        while !images.isEmpty {
            
            if writer.isReadyForData == false {
                // Inform writer we have more buffers to write.
                return false
            }
            
            let image = images.removeFirst()
            let presentationTime = CMTimeMultiply(frameDuration, multiplier: Int32(frameNum))
            let success = videoWriter.addImage(image: image, withPresentationTime: presentationTime)
            if success == false {
                fatalError("addImage() failed")
            }
            else {
                print("Added image @ frame \(frameNum) with presTime: \(presentationTime)")
            }
            
            frameNum += 1
        }
        
        // Inform writer all buffers have been written.
        return true
    }
    
}

@available(iOS 11.0, *)
public class VideoWriter {
    
    let renderSettings: RenderSettings
    
    var videoWriter: AVAssetWriter!
    var videoWriterInput: AVAssetWriterInput!
    var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor!
    
    var isReadyForData: Bool {
        return videoWriterInput?.isReadyForMoreMediaData ?? false
    }
    
    class func pixelBufferFromImage(image: UIImage, pixelBufferPool: CVPixelBufferPool, size: CGSize, alpha:CGImageAlphaInfo) -> CVPixelBuffer? {
        
        //        let inputCGImage =  CIImage(image: image)!.convertCIImageToCGImage()!
        //
        //        let colorSpace       = CGColorSpaceCreateDeviceRGB()
        //        let width            = inputCGImage.width
        //        let height           = inputCGImage.height
        //        let bytesPerPixel    = 4
        //        let bitsPerComponent = 8
        //        let bytesPerRow      = bytesPerPixel * width
        //        let bitmapInfo       = RGBA32.bitmapInfo
        //
        //
        //        guard let context1 = CGContext(data: nil, width: width, height: height, bitsPerComponent: bitsPerComponent, bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: bitmapInfo) else {
        //            print("Couldn't create CGContext")
        //            return nil
        //        }
        //
        //        context1.draw(inputCGImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        //
        //        guard let buffer = context1.data else {
        //            print("unable to get context data")
        //            return nil
        //        }
        //
        //        let oldPixelBuffer = buffer.bindMemory(to: RGBA32.self, capacity: width * height)
        
        var pixelBufferOut: CVPixelBuffer?
        
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pixelBufferPool, &pixelBufferOut)
        if status != kCVReturnSuccess {
            fatalError("CVPixelBufferPoolCreatePixelBuffer() failed")
        }
        
        let pixelBuffer = pixelBufferOut!
        
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        
        let data = CVPixelBufferGetBaseAddress(pixelBuffer)
        let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: data, width: Int(size.width), height: Int(size.height),
                                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer), space: rgbColorSpace, bitmapInfo: alpha.rawValue)
        
        context!.clear(CGRect(x: 0, y: 0, width: size.width, height: size.height))
        
        let horizontalRatio = size.width / image.size.width
        let verticalRatio = size.height / image.size.height
        //aspectRatio = max(horizontalRatio, verticalRatio) // ScaleAspectFill
        let aspectRatio = min(horizontalRatio, verticalRatio) // ScaleAspectFit
        
        let newSize = CGSize(width: image.size.width * aspectRatio, height: image.size.height * aspectRatio)
        
        let x = newSize.width < size.width ? (size.width - newSize.width) / 2 : 0
        let y = newSize.height < size.height ? (size.height - newSize.height) / 2 : 0
        
        context!.draw(image.cgImage!, in: CGRect(x: x, y: y, width: newSize.width, height: newSize.height))
        
        let newPixelBuffer = data!.bindMemory(to: RGBA32.self, capacity: Int(newSize.width * newSize.height))
        
        for row in 0 ..< Int(newSize.height) {
            for column in 0 ..< Int(newSize.width) {
                let offset = row * Int(newSize.width) + column
                //Blue -- GREEN -- RED --
                if(newPixelBuffer[offset] == RGBA32.black) {
                    newPixelBuffer[offset] = RGBA32.init(red: 0, green: 255, blue: 0, alpha: 255)
                }
            }
        }
        
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        return pixelBuffer
    }
    
    @available(iOS 11.0, *)
    init(renderSettings: RenderSettings) {
        self.renderSettings = renderSettings
    }
    
    func start() {
        
        let avOutputSettings: [String: AnyObject] = [
            AVVideoCodecKey: renderSettings.avCodecKey as AnyObject,
            AVVideoWidthKey: NSNumber(value: Float(renderSettings.width)),
            AVVideoHeightKey: NSNumber(value: Float(renderSettings.height))
        ]
        
        func createPixelBufferAdaptor() {
            let sourcePixelBufferAttributesDictionary = [
                kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: kCVPixelFormatType_32ARGB),
                kCVPixelBufferWidthKey as String: NSNumber(value: Float(renderSettings.width)),
                kCVPixelBufferHeightKey as String: NSNumber(value: Float(renderSettings.height))
            ]
            pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoWriterInput,
                                                                      sourcePixelBufferAttributes: sourcePixelBufferAttributesDictionary)
        }
        
        func createAssetWriter(outputURL: URL) -> AVAssetWriter {
            guard let assetWriter = try? AVAssetWriter(outputURL: outputURL, fileType: AVFileType.mp4) else {
                fatalError("AVAssetWriter() failed")
            }
            
            guard assetWriter.canApply(outputSettings: avOutputSettings, forMediaType: AVMediaType.video) else {
                fatalError("canApplyOutputSettings() failed")
            }
            
            return assetWriter
        }
        
        videoWriter = createAssetWriter(outputURL: renderSettings.outputURL)
        videoWriterInput = AVAssetWriterInput(mediaType: AVMediaType.video, outputSettings: avOutputSettings)
        
        if videoWriter.canAdd(videoWriterInput) {
            videoWriter.add(videoWriterInput)
        }
        else {
            fatalError("canAddInput() returned false")
        }
        
        // The pixel buffer adaptor must be created before we start writing.
        createPixelBufferAdaptor()
        
        if videoWriter.startWriting() == false {
            fatalError("startWriting() failed")
        }
        
        videoWriter.startSession(atSourceTime: CMTime.zero)
        
        precondition(pixelBufferAdaptor.pixelBufferPool != nil, "nil pixelBufferPool")
    }
    
    func render(appendPixelBuffers: @escaping (VideoWriter)->Bool, completion: @escaping ()->Void) {
        
        precondition(videoWriter != nil, "Call start() to initialze the writer")
        
        let queue = DispatchQueue(__label: "mediaInputQueue", attr: nil)
        videoWriterInput.requestMediaDataWhenReady(on: queue) {
            let isFinished = appendPixelBuffers(self)
            if isFinished {
                self.videoWriterInput.markAsFinished()
                self.videoWriter.finishWriting() {
                    DispatchQueue.main.async {
                        print("Done Creating Video")
                        completion()
                    }
                }
            }
            else {
                // Fall through. The closure will be called again when the writer is ready.
            }
        }
    }
    
    func addImage(image: UIImage, withPresentationTime presentationTime: CMTime) -> Bool {
        
        precondition(pixelBufferAdaptor != nil, "Call start() to initialze the writer")
        
        //1
        let pixelBuffer = VideoWriter.pixelBufferFromImage(image: image, pixelBufferPool: pixelBufferAdaptor.pixelBufferPool!, size: renderSettings.size, alpha: CGImageAlphaInfo.premultipliedFirst)!
        let image1 = UIImage(pixelBuffer: pixelBuffer)
        
        return pixelBufferAdaptor.append(pixelBuffer, withPresentationTime: presentationTime)
    }
    
}
