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
    
    public convenience init(fps: Int32, width: CGFloat, height: CGFloat, audioSettings: [String:Any]?) {
        self.init()
        self.settings = RenderSettings(fps: fps, width: width, height: height)
        self.imageAnimator = ImageAnimator(renderSettings: self.settings, audioSettings: audioSettings)
    }
    
    public convenience init(width: CGFloat, height: CGFloat) {
        self.init()
        self.settings = RenderSettings(width: width, height: height)
        self.imageAnimator = ImageAnimator(renderSettings: self.settings)
    }
    
    func startCreatingVideo(initialBuffer: CMSampleBuffer?, completion: @escaping (() -> Void)) {
        self.imageAnimator.render(initialBuffer: initialBuffer) {
            completion()
        }
    }
    
    func finishWriting() {
        self.imageAnimator.isDone = true
    }
    
    func addImageAndAudio(image:UIImage, audio:CMSampleBuffer?, time:CFAbsoluteTime) {
        self.imageAnimator.addImageAndAudio(image: image, audio: audio, time: time)
    }
    
    func getURL() -> URL {
        return settings!.outputURL
    }
    
    func addAudio(audio: CMSampleBuffer, time: CMTime) {
        self.imageAnimator.videoWriter.addAudio(buffer: audio, time: time)
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
    var imagesAndAudio:SynchronizedArray<(UIImage, CMSampleBuffer?, CFAbsoluteTime)> = SynchronizedArray<(UIImage, CMSampleBuffer?, CFAbsoluteTime)>()
    var isDone:Bool = false
    let semaphore = DispatchSemaphore(value: 1)
    
    var frameNum = 0
    
    class func removeFileAtURL(fileURL: URL) {
        do {
            try FileManager.default.removeItem(atPath: fileURL.path)
        }
        catch _ as NSError {
            // Assume file doesn't exist.
        }
    }
    
    init(renderSettings: RenderSettings, audioSettings:[String:Any]? = nil) {
        settings = renderSettings
        videoWriter = VideoWriter(renderSettings: settings, audioSettings: audioSettings)
    }
    
    func addImageAndAudio(image: UIImage, audio: CMSampleBuffer?, time:CFAbsoluteTime) {
        self.imagesAndAudio.append((image, audio, time))
//        print("Adding to array -- \(self.imagesAndAudio.count)")
    }
    
    func render(initialBuffer: CMSampleBuffer?, completion: @escaping ()->Void) {
        
        // The VideoWriter will fail if a file exists at the URL, so clear it out first.
        ImageAnimator.removeFileAtURL(fileURL: settings.outputURL)
        
        videoWriter.start(initialBuffer: initialBuffer)
        videoWriter.render(appendPixelBuffers: appendPixelBuffers) {
            //ImageAnimator.saveToLibrary(self.settings.outputURL)
            completion()
        }
        
    }
    
    // This is the callback function for VideoWriter.render()
    func appendPixelBuffers(writer: VideoWriter) -> Bool {
        
        //Don't stop while images are NOT empty
        while !imagesAndAudio.isEmpty || !isDone {
            
            if(!imagesAndAudio.isEmpty) {
                let date = Date()
                
                if writer.isReadyForVideoData == false {
                    // Inform writer we have more buffers to write.
//                    print("Writer is not ready for more data")
                    return false
                }
                
                autoreleasepool {
                    //This should help but truly doesn't suffice - still need a mutex/lock
                    if(!imagesAndAudio.isEmpty) {
                        semaphore.wait() // requesting resource
                        let imageAndAudio = imagesAndAudio.first()!
                        let image = imageAndAudio.0
//                        let audio = imageAndAudio.1
                        let time = imageAndAudio.2
                        self.imagesAndAudio.removeAtIndex(index: 0)
                        semaphore.signal() // releasing resource
                        let presentationTime = CMTime(seconds: time, preferredTimescale: 600)
                        
//                        if(audio != nil) { videoWriter.addAudio(buffer: audio!) }
                        let success = videoWriter.addImage(image: image, withPresentationTime: presentationTime)
                        if success == false {
                            fatalError("addImage() failed")
                        }
                        else {
//                            print("Added image @ frame \(frameNum) with presTime: \(presentationTime)")
                        }
                    
                        frameNum += 1
                        let final = Date()
                        let timeDiff = final.timeIntervalSince(date)
//                        print("Time: \(timeDiff)")
                    }
                    else {
//                        print("Images was empty")
                    }
                }
            }
        }
        
        print("Done writing")
        // Inform writer all buffers have been written.
        return true
    }
    
}

@available(iOS 11.0, *)
public class VideoWriter {
    
    let renderSettings: RenderSettings
    var audioSettings: [String:Any]?
    var videoWriter: AVAssetWriter!
    var videoWriterInput: AVAssetWriterInput!
    var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor!
    var audioWriterInput: AVAssetWriterInput!
    static var ci:Int = 0
    var initialTime:CMTime!
    
    var isReadyForVideoData: Bool {
        return (videoWriterInput == nil ? false : videoWriterInput!.isReadyForMoreMediaData )
    }
    
    var isReadyForAudioData: Bool {
        return (audioWriterInput == nil ? false : audioWriterInput!.isReadyForMoreMediaData)
    }
    
    class func pixelBufferFromImage(image: UIImage, pixelBufferPool: CVPixelBufferPool, size: CGSize, alpha:CGImageAlphaInfo) -> CVPixelBuffer? {
        
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
        
        let cgImage = image.cgImage != nil ? image.cgImage! : image.ciImage!.convertCIImageToCGImage()
        
        context!.draw(cgImage!, in: CGRect(x: x, y: y, width: newSize.width, height: newSize.height))
        
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        return pixelBuffer
    }
    
    @available(iOS 11.0, *)
    init(renderSettings: RenderSettings, audioSettings:[String:Any]? = nil) {
        self.renderSettings = renderSettings
        self.audioSettings = audioSettings
    }
    
    func start(initialBuffer: CMSampleBuffer?) {
        
        let avOutputSettings: [String: AnyObject] = [
            AVVideoCodecKey: renderSettings.avCodecKey as AnyObject,
            AVVideoWidthKey: NSNumber(value: Float(renderSettings.width)),
            AVVideoHeightKey: NSNumber(value: Float(renderSettings.height))
        ]
        
        let avAudioSettings = audioSettings
        
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
            guard let assetWriter = try? AVAssetWriter(outputURL: outputURL, fileType: AVFileType.mov) else {
                fatalError("AVAssetWriter() failed")
            }
            
            guard assetWriter.canApply(outputSettings: avOutputSettings, forMediaType: AVMediaType.video) else {
                fatalError("canApplyOutputSettings() failed")
            }
            
            return assetWriter
        }
        
        videoWriter = createAssetWriter(outputURL: renderSettings.outputURL)
        videoWriterInput = AVAssetWriterInput(mediaType: AVMediaType.video, outputSettings: avOutputSettings)
//        if(audioSettings != nil) {
        audioWriterInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
        audioWriterInput.expectsMediaDataInRealTime = true
//        }
        
        if videoWriter.canAdd(videoWriterInput) {
            videoWriter.add(videoWriterInput)
        }
        else {
            fatalError("canAddInput() returned false")
        }
        
//        if(audioSettings != nil) {
            if videoWriter.canAdd(audioWriterInput) {
                videoWriter.add(audioWriterInput)
            }
            else {
                fatalError("canAddInput() returned false")
            }
//        }
        
        // The pixel buffer adaptor must be created before we start writing.
        createPixelBufferAdaptor()
        
        if videoWriter.startWriting() == false {
            fatalError("startWriting() failed")
        }
        
        
        self.initialTime = initialBuffer != nil ? CMSampleBufferGetPresentationTimeStamp(initialBuffer!) : CMTime.zero
        videoWriter.startSession(atSourceTime: self.initialTime)
        
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
    
    func addAudio(buffer: CMSampleBuffer, time: CMTime) {
        if(self.audioWriterInput != nil && self.audioWriterInput.isReadyForMoreMediaData) {
            print("Writing audio \(VideoWriter.ci) of a time of \(CMSampleBufferGetPresentationTimeStamp(buffer))")
            self.audioWriterInput.append(buffer)
        }
        VideoWriter.ci += 1
    }
    
    func addImage(image: UIImage, withPresentationTime presentationTime: CMTime) -> Bool {
        
        precondition(pixelBufferAdaptor != nil, "Call start() to initialze the writer")
        //1
        let pixelBuffer = VideoWriter.pixelBufferFromImage(image: image, pixelBufferPool: pixelBufferAdaptor.pixelBufferPool!, size: renderSettings.size, alpha: CGImageAlphaInfo.premultipliedFirst)!
        
        return pixelBufferAdaptor.append(pixelBuffer, withPresentationTime: presentationTime + self.initialTime)
    }
}
