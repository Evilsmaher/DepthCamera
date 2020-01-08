//
//  VideoCapture.swift
//  Camera
//
//  Created by Bradley French on 7/3/19.
//  Copyright © 2019 Bradley French. All rights reserved.
//
import AVFoundation
import Foundation
import UIKit
import Accelerate.vImage

struct VideoSpec {
    var fps: Int32?
    var size: CGSize?
}

typealias ImageBufferHandler = (CVPixelBuffer, CMTime, CVPixelBuffer?) -> Void
typealias AudioBufferHandler = (CMSampleBuffer, CMTime) -> Void
typealias SynchronizedDataBufferHandler = (CVPixelBuffer, CVPixelBuffer, AVMetadataObject?) -> Void

extension AVCaptureDevice {
    func printDepthFormats() {
        formats.forEach { (format) in
            let depthFormats = format.supportedDepthDataFormats
            if depthFormats.count > 0 {
                print("format: \(format), supported depth formats: \(depthFormats)")
            }
        }
    }
}

class VideoCapture: NSObject {
    
    private let captureSession = AVCaptureSession()
    private var videoDevice: AVCaptureDevice!
    private var videoConnection: AVCaptureConnection!
    private var audioConnection: AVCaptureConnection!
    private var previewLayer: AVCaptureVideoPreviewLayer?
    
    let dataOutputQueue = DispatchQueue(label: "video data queue",
                                        qos: .userInitiated,
                                        attributes: [],
                                        autoreleaseFrequency: .workItem)
    let audioOutputQueue = DispatchQueue(label: "audio data queue",
                                        qos: .userInitiated,
                                        attributes: [],
                                        autoreleaseFrequency: .workItem)
    private let serialQueue = DispatchQueue(label: "com.myQueue.queue")

    
    var imageBufferHandler: ImageBufferHandler?
    var audioBufferHandler: AudioBufferHandler?
    var syncedDataBufferHandler: SynchronizedDataBufferHandler?
    
    private var dataOutputSynchronizer: AVCaptureDataOutputSynchronizer!
    private var audioDeviceInput: AVCaptureDeviceInput!
    
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let audioDataOutput = AVCaptureAudioDataOutput()
    private let depthDataOutput = AVCaptureDepthDataOutput()
    private let metadataOutput = AVCaptureMetadataOutput()
    
    private var cameraMode:CameraMode!
    private var sessionAtSourceTime:CMTime!
    private var videoURL:URL!
    
    var buffer:CVPixelBuffer!
    var depthBuffer:CVPixelBuffer!
    private var converter: vImageConverter?
    var cgImageFormat = vImage_CGImageFormat(
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        colorSpace: nil,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.first.rawValue),
        version: 0,
        decode: nil,
        renderingIntent: .defaultIntent)
    var sourceBuffers = [vImage_Buffer]()
    var destinationBuffer = vImage_Buffer()
    var frameRate:Int32!
    lazy var audioSettings = AVCaptureAudioDataOutput().recommendedAudioSettingsForAssetWriter(writingTo: .mp4)
    var totalLag:Double = 0
    var currentLag:UInt64 = 0
    var observer:NSKeyValueObservation!
    
    init(cameraMode: CameraMode, cameraType: CameraType, preferredSpec: VideoSpec?, previewContainer: CALayer?)
    {
        super.init()
        
        self.cameraMode = cameraMode
        
        captureSession.beginConfiguration()
        
        //If I use video - it inverts the green and regular
//        captureSession.sessionPreset = self.cameraMode == .photo ? AVCaptureSession.Preset.photo : AVCaptureSession.Preset.high
        captureSession.sessionPreset = .photo
        print("Session is: \(captureSession.sessionPreset)")
        
        setupCaptureVideoDevice(with: cameraType)
        
        self.frameRate = videoDevice.getBestFPS() ?? 24 //24 is slowest anyone should use -- this shouldn't fail, but incase it does
        
        setupCaptureAudioDevice()
        
        // setup preview
        if let previewContainer = previewContainer {
            let previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
            previewLayer.frame = previewContainer.bounds
            previewLayer.contentsGravity = CALayerContentsGravity.resizeAspectFill
            previewLayer.videoGravity = .resizeAspectFill
            previewContainer.insertSublayer(previewLayer, at: 0)
            self.previewLayer = previewLayer
        }
        
        // setup outputs
        do {
            // video output
            videoDataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
            videoDataOutput.alwaysDiscardsLateVideoFrames = true
            audioDataOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mp4)
            
            videoDataOutput.setSampleBufferDelegate(self, queue: dataOutputQueue)
            guard captureSession.canAddOutput(videoDataOutput) else { fatalError() }
            captureSession.addOutput(videoDataOutput)
            videoConnection = videoDataOutput.connection(with: .video)
            
            // depth output
            guard captureSession.canAddOutput(depthDataOutput) else { fatalError() }
            captureSession.addOutput(depthDataOutput)
            depthDataOutput.setDelegate(self, callbackQueue: dataOutputQueue)
            depthDataOutput.isFilteringEnabled = false
            guard let connection = depthDataOutput.connection(with: .depthData) else { fatalError() }
            connection.isEnabled = true
            
            // audio output
            guard captureSession.canAddOutput(audioDataOutput) else { fatalError() }
            captureSession.addOutput(audioDataOutput)
            audioDataOutput.setSampleBufferDelegate(self, queue: audioOutputQueue)
            audioConnection = audioDataOutput.connection(with: .audio)
            
            // metadata output
            guard captureSession.canAddOutput(metadataOutput) else { fatalError() }
            captureSession.addOutput(metadataOutput)
            if metadataOutput.availableMetadataObjectTypes.contains(.face) {
                metadataOutput.metadataObjectTypes = [.face]
            }
            
            // synchronize outputs
            dataOutputSynchronizer = AVCaptureDataOutputSynchronizer(dataOutputs: [videoDataOutput, depthDataOutput, metadataOutput])
            dataOutputSynchronizer.setDelegate(self, queue: dataOutputQueue)
        }
        
        setupConnections(with: cameraType)
        
        captureSession.commitConfiguration()
        self.observer = self.captureSession.observe(\.isRunning, options: [.initial]) { [weak self](session, change) in
            guard let self = self else { return }
            if(!session.isRunning) { self.currentLag = DispatchTime.now().uptimeNanoseconds }
            else {
                self.currentLag = (DispatchTime.now().uptimeNanoseconds - self.currentLag)
                self.totalLag += Double(Double(self.currentLag) / Double(1_000_000_000))
            }
        }
    }
    
    private func setupCaptureAudioDevice() {
        guard let audioDevice = AVCaptureDevice.default(for: .audio) else {fatalError()}
        do {
            audioDeviceInput = try AVCaptureDeviceInput(device: audioDevice)
        }
        catch {
            fatalError("Could not create AVCaptureDeviceInput instance with error: \(error).")
        }
        guard captureSession.canAddInput(audioDeviceInput) else {
            fatalError()
        }
        captureSession.addInput(audioDeviceInput)
    }
    
    private func setupCaptureVideoDevice(with cameraType: CameraType) {
        
        videoDevice = cameraType.captureDevice()
        print("selected video device: \(String(describing: videoDevice))")
        
        videoDevice.selectDepthFormat()
        

        captureSession.inputs.forEach { (captureInput) in
            if(captureInput != audioDeviceInput) {
                captureSession.removeInput(captureInput)
            }
        }
        
        let videoDeviceInput = try! AVCaptureDeviceInput(device: videoDevice)
        guard captureSession.canAddInput(videoDeviceInput) else { fatalError() }
        captureSession.addInput(videoDeviceInput)
    }
    
    private func setupConnections(with cameraType: CameraType) {
        videoConnection = videoDataOutput.connection(with: .video)!
        let depthConnection = depthDataOutput.connection(with: .depthData)
        switch cameraType {
        case .front:
            videoConnection.isVideoMirrored = true
            depthConnection?.isVideoMirrored = true
        default:
            break
        }
        videoConnection.videoOrientation = .portrait
        depthConnection?.videoOrientation = .portrait
    }
    
    func startCapture() {
        print("\(self.classForCoder)/" + #function)
        if captureSession.isRunning {
            print("already running")
            return
        }
        captureSession.startRunning()
    }
    
    func stopCapture() {
        print("\(self.classForCoder)/" + #function)
        if !captureSession.isRunning {
            print("already stopped")
            return
        }
        captureSession.stopRunning()
    }
    
    func resizePreview() {
        if let previewLayer = previewLayer {
            guard let superlayer = previewLayer.superlayer else {return}
            previewLayer.frame = superlayer.bounds
        }
    }
    
    func changeCamera(with cameraType: CameraType) {
        let wasRunning = captureSession.isRunning
        if wasRunning {
            captureSession.stopRunning()
        }
        captureSession.beginConfiguration()
        
        setupCaptureVideoDevice(with: cameraType)
        setupConnections(with: cameraType)
        
        captureSession.commitConfiguration()
        
        if wasRunning {
            captureSession.startRunning()
        }
    }
    
    func setDepthFilterEnabled(_ enabled: Bool) {
        depthDataOutput.isFilteringEnabled = enabled
    }
    
    func setCameraMode(cameraMode: CameraMode) {
        self.cameraMode = cameraMode
    }
}

extension VideoCapture: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    
    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        //        print("\(self.classForCoder)/" + #function)
    }
    
    // synchronizer使ってる場合は呼ばれない
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
//        print("Handling here")
        if let imageBufferHandler = imageBufferHandler, connection == videoConnection
        {
//            print("Video Data")
            guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { fatalError() }
            
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            imageBufferHandler(imageBuffer, timestamp, nil)
        }
        
        else if let audioBufferHandler = audioBufferHandler, connection == audioConnection {
//            print("Obtaining Audio Stamp")
            let time = CMTime(seconds: self.totalLag, preferredTimescale: 600)
            audioBufferHandler(sampleBuffer, time)
        }
    }
}

extension VideoCapture: AVCaptureDepthDataOutputDelegate {
    
    func depthDataOutput(_ output: AVCaptureDepthDataOutput, didDrop depthData: AVDepthData, timestamp: CMTime, connection: AVCaptureConnection, reason: AVCaptureOutput.DataDroppedReason) {
//        print("\(self.classForCoder)/\(#function)")
    }
    
    // synchronizer使ってる場合は呼ばれない
    func depthDataOutput(_ output: AVCaptureDepthDataOutput, didOutput depthData: AVDepthData, timestamp: CMTime, connection: AVCaptureConnection) {
//        print("\(self.classForCoder)/\(#function)")
    }
}

extension VideoCapture: AVCaptureDataOutputSynchronizerDelegate {
    
    func dataOutputSynchronizer(_ synchronizer: AVCaptureDataOutputSynchronizer, didOutput synchronizedDataCollection: AVCaptureSynchronizedDataCollection) {
        
//        print(self.videoDevice.activeVideoMinFrameDuration, self.videoDevice.activeVideoMaxFrameDuration)
        guard let syncedVideoData = synchronizedDataCollection.synchronizedData(for: self.videoDataOutput) as? AVCaptureSynchronizedSampleBufferData else { return }
        guard !syncedVideoData.sampleBufferWasDropped else {
            print(syncedVideoData.droppedReason.rawValue)
            return
        }
        let videoSampleBuffer = syncedVideoData.sampleBuffer
        
        let syncedDepthData = synchronizedDataCollection.synchronizedData(for: self.depthDataOutput) as? AVCaptureSynchronizedDepthData
        var depthData = syncedDepthData?.depthData
        if let syncedDepthData = syncedDepthData, syncedDepthData.depthDataWasDropped {
            print("dropped depth:\(syncedDepthData)")
            depthData = nil
        }
        
        let syncedMetaData = synchronizedDataCollection.synchronizedData(for: self.metadataOutput) as? AVCaptureSynchronizedMetadataObjectData
        var face: AVMetadataObject? = nil
        if let firstFace = syncedMetaData?.metadataObjects.first {
            face = self.videoDataOutput.transformedMetadataObject(for: firstFace, connection: self.videoConnection)
        }
        guard let imagePixelBuffer = CMSampleBufferGetImageBuffer(videoSampleBuffer) else { fatalError() }
        guard let depthMap = depthData?.depthDataMap else { return }
        
        CVPixelBufferLockBaseAddress(imagePixelBuffer,
                                     CVPixelBufferLockFlags.readOnly)
        
        self.buffer = displayEqualizedPixelBuffer(pixelBuffer: imagePixelBuffer)
        
        CVPixelBufferUnlockBaseAddress(imagePixelBuffer,
                                       CVPixelBufferLockFlags.readOnly)
        
        CVPixelBufferLockBaseAddress(depthMap,
                                     CVPixelBufferLockFlags.readOnly)
        
        self.depthBuffer = displayEqualizedPixelBuffer(pixelBuffer: depthMap, scaleToBuffer: imagePixelBuffer)
        
        CVPixelBufferUnlockBaseAddress(depthMap, CVPixelBufferLockFlags.readOnly)
        
        self.syncedDataBufferHandler?(self.buffer, self.depthBuffer, face)
    }
    
    func displayEqualizedPixelBuffer(pixelBuffer: CVPixelBuffer, scaleToBuffer: CVPixelBuffer? = nil) -> CVPixelBuffer? {
        
        let scaleWidth:Int = scaleToBuffer != nil ? CVPixelBufferGetWidth(scaleToBuffer!) : CVPixelBufferGetWidth(pixelBuffer)
        let scaleHeight:Int = scaleToBuffer != nil ? CVPixelBufferGetHeight(scaleToBuffer!) : CVPixelBufferGetHeight(pixelBuffer)
        
        let flags = CVPixelBufferLockFlags(rawValue: 0)
        guard kCVReturnSuccess == CVPixelBufferLockBaseAddress(pixelBuffer, flags) else {
            return nil
        }
        
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, flags) }
        
        guard let srcData = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            print("Error: could not get pixel buffer base address")
            return nil
        }
        
        let srcBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        var srcBuffer = vImage_Buffer(data: srcData,
                                      height: vImagePixelCount(CVPixelBufferGetHeight(pixelBuffer)),
                                      width: vImagePixelCount(CVPixelBufferGetWidth(pixelBuffer)),
                                      rowBytes: srcBytesPerRow)
        
        let destBytesPerRow = scaleWidth*4
        guard let destData = malloc(scaleHeight*destBytesPerRow) else {
            print("Error: out of memory")
            return nil
        }
        
        var destBuffer = vImage_Buffer(data: destData,
                                       height: vImagePixelCount(scaleHeight),
                                       width: vImagePixelCount(scaleWidth),
                                       rowBytes: destBytesPerRow)
        
        let error = vImageScale_ARGB8888(&srcBuffer, &destBuffer, nil, vImage_Flags(kvImageLeaveAlphaUnchanged))
        if error != kvImageNoError {
            print("Error:", error)
            free(destData)
            return nil
        }
        
        let releaseCallback: CVPixelBufferReleaseBytesCallback = { _, ptr in
            if let ptr = ptr {
                free(UnsafeMutableRawPointer(mutating: ptr))
            }
        }
        
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        var dstPixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreateWithBytes(nil, scaleWidth, scaleHeight,
                                                  pixelFormat, destData,
                                                  destBytesPerRow, releaseCallback,
                                                  nil, nil, &dstPixelBuffer)
        if status != kCVReturnSuccess {
            print("Error: could not create new pixel buffer")
            free(destData)
            return nil
        }
        return dstPixelBuffer
    }
}

extension AVCaptureDevice {
    func getBestFPS() -> Int32? {
        guard let range = activeFormat.videoSupportedFrameRateRanges.first else {
            print("Couldn't get a supported FPS")
            return nil
        }
        do {
            try lockForConfiguration()
            activeVideoMinFrameDuration = CMTimeMake(value: 1, timescale: Int32(range.maxFrameRate))
            activeVideoMaxFrameDuration = CMTimeMake(value: 1, timescale: Int32(range.maxFrameRate))
            print("Frame Rate is: \(activeVideoMinFrameDuration) and \(activeVideoMaxFrameDuration)")
            unlockForConfiguration()
            return Int32(range.maxFrameRate)
        } catch {
            print("LockForConfiguration failed with error: \(error.localizedDescription)")
            return nil
        }
    }
}
