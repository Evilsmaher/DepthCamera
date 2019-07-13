//
//  MetalRenderer.swift
//
//  Created by Bradley French on 7/3/19.
//  Copyright © 2019 Bradley French. All rights reserved.
//
import Metal
import MetalKit

// The max number of command buffers in flight
let kMaxBuffersInFlight: Int = 1

// Vertex data for an image plane
let kImagePlaneVertexData: [Float] = [
    -1.0, -1.0,  0.0, 1.0,
    1.0, -1.0,  1.0, 1.0,
    -1.0,  1.0,  0.0, 0.0,
    1.0,  1.0,  1.0, 0.0,
]

class MetalRenderer {
    private let device: MTLDevice
    private let inFlightSemaphore = DispatchSemaphore(value: kMaxBuffersInFlight)
    private var renderDestination: MTKView
    
    private var commandQueue: MTLCommandQueue!
    private var vertexBuffer: MTLBuffer!
    private var passThroughPipeline: MTLRenderPipelineState!
    
    init(metalDevice device: MTLDevice, renderDestination: MTKView) {
        self.device = device
        self.renderDestination = renderDestination
        
        // Set the default formats needed to render
        self.renderDestination.colorPixelFormat = .bgra8Unorm
        self.renderDestination.sampleCount = 1
        
        commandQueue = device.makeCommandQueue()
        
        let lib = device.makeDefaultLibrary(Bundle: Bundle(name: RealtimeDepthMaskViewController.self))!
        prepareRenderPipelines(library: lib)
        
        // prepare vertex buffer(s)
        let imagePlaneVertexDataCount = kImagePlaneVertexData.count * MemoryLayout<Float>.size
        vertexBuffer = device.makeBuffer(bytes: kImagePlaneVertexData, length: imagePlaneVertexDataCount, options: [])
        vertexBuffer.label = "vertexBuffer"
    }
    
    private let ciContext = CIContext()
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    
    func update(with ciImage: CIImage) {
        // Wait to ensure only kMaxBuffersInFlight are getting proccessed by any stage in the Metal
        // pipeline (App, Metal, Drivers, GPU, etc)
        let _ = inFlightSemaphore.wait(timeout: .distantFuture)
        
        guard
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let currentDrawable = renderDestination.currentDrawable
            else {
                inFlightSemaphore.signal()
                return
        }
        commandBuffer.label = "MyCommand"
        
        commandBuffer.addCompletedHandler{ [weak self] commandBuffer in
            if let strongSelf = self {
                strongSelf.inFlightSemaphore.signal()
            }
        }
        //Won't ever get here if not simulator because I also check this inside RealTimeDepthViewController but need to check so the pod will compile
        #if targetEnvironment(simulator)
        #else
        ciContext.render(ciImage, to: currentDrawable.texture, commandBuffer: commandBuffer, bounds: ciImage.extent, colorSpace: colorSpace)
        
        commandBuffer.present(currentDrawable)
        commandBuffer.commit()
        #endif
    }
    
    // MARK: - Private
    
    // Create render pipeline states
    private func prepareRenderPipelines(library: MTLLibrary) {
        let passThroughVertexFunction = library.passThroughVertexFunction
        let passThroughFragmentFunction = library.passThroughFragmentFunction
        
        // Create a vertex descriptor for our image plane vertex buffer
        let imagePlaneVertexDescriptor = MTLVertexDescriptor()
        
        // Positions.
        imagePlaneVertexDescriptor.attributes[0].format = .float2
        imagePlaneVertexDescriptor.attributes[0].offset = 0
        imagePlaneVertexDescriptor.attributes[0].bufferIndex = 0
        
        // Texture coordinates.
        imagePlaneVertexDescriptor.attributes[1].format = .float2
        imagePlaneVertexDescriptor.attributes[1].offset = 8
        imagePlaneVertexDescriptor.attributes[1].bufferIndex = 0
        
        // Buffer Layout
        imagePlaneVertexDescriptor.layouts[0].stride = 16
        imagePlaneVertexDescriptor.layouts[0].stepRate = 1
        imagePlaneVertexDescriptor.layouts[0].stepFunction = .perVertex
        
        let createPipeline = { (fragmentFunction: MTLFunction, sampleCount: Int?, pixelFormat: MTLPixelFormat) -> MTLRenderPipelineState in
            let pipelineDescriptor = MTLRenderPipelineDescriptor()
            if let sampleCount = sampleCount {
                pipelineDescriptor.sampleCount = sampleCount
            }
            pipelineDescriptor.vertexFunction = passThroughVertexFunction
            pipelineDescriptor.fragmentFunction = fragmentFunction
            pipelineDescriptor.vertexDescriptor = imagePlaneVertexDescriptor
            pipelineDescriptor.colorAttachments[0].pixelFormat = pixelFormat
            //            pipelineDescriptor.depthAttachmentPixelFormat = MTLPixelFormat.depth32Float
            return try! self.device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        }
        
        passThroughPipeline   = createPipeline(passThroughFragmentFunction, renderDestination.sampleCount, renderDestination.colorPixelFormat)
    }
}

extension MTLLibrary {
    
    var passThroughVertexFunction: MTLFunction {
        return makeFunction(name: "passThroughVertex")!
    }
    
    var passThroughFragmentFunction: MTLFunction {
        return makeFunction(name: "passThroughFragment")!
    }
}

extension MTLRenderCommandEncoder {
    
    func encode(renderPipeline: MTLRenderPipelineState, vertexBuffer: MTLBuffer, textures: [MTLTexture]) {
        setRenderPipelineState(renderPipeline)
        setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        var index: Int = 0
        textures.forEach { (texture) in
            setFragmentTexture(texture, index: index)
            index += 1
        }
        drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }
}
