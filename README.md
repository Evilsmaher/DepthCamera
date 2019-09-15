# DepthCamera
_DepthCamera_

*Add To Your Project*
In your `Podfile` add `pod 'DepthCamera'`.
Then, wherever you need to make calls, `import DepthCamera` into that specific file. 

*Details*

Usage: Record a video or image in a 2D or 3D format. 
How: Reads data buffers in using a `AVCaptureDataOutputSynchronizerDelegate`. If using the 3D environment, it then applies a filter from the depth data. This is the simulated 3D affect. If recording a video, it will asynchronously add images to a video. To achieve this affect, the images are added at an unknown rate. To further explain this, look @ _Video Creation Details_ below. If an image, then it simply records the image. From there, the image or video can be obtained and represented in either a 2D (AVPlayer) format or 3D (ARKit) format. To see how to use each of these, please reference the _Video Viewing_  below. On how to record a video, please reference _Video Recording_ below.
Assumptions: The user has a phone that is capable of using these assets.

*Video Creation Details*

The `MTKViewDelegate` inside "RealTimeDepthViewController" is what calls the asynchronous calls to adding images to the `VideoCreator` that creates the video. Well, although, the delegate is supposed to record at a specific FPS, the code inside causes it to record "when it can". This leads to unidentified times per frame. Since that is the case, I have to set a presentation time for each frame. But, those frames can range at unknown times. For my tests, I have seen between 0.04 and 0.08 frame times, which is between 14 - 25 fps. Although it isn't perfect, it's pretty good looking. However, the audio is recorded at a normal rate and can be heard as if it was recorded at a normal rate.


*Video Recording*

To take an image:
```
let controller = RealtimeDepthMaskViewController.createRealTimeDepthCameraVC(imageOrVideoCaptureMode: .photo, completionHandler: { (image, _) in
                    //Do something with image
                }, backgroundImages: nil)
self.present(controller, animated: true, completion: nil)
```

To take a video:
```
let controller = RealtimeDepthMaskViewController.createRealTimeDepthCameraVC(imageOrVideoCaptureMode: .video, completionHandler: { (_, url) in
                    //Do something with url
                }, backgroundImages: nil)
self.present(controller, animated: true, completion: nil)
```

It's as simple as creating a `RealTimeDepthViewController` and presenting it. You just need to state whether it is a video or a photo. From there, just make sure to use the completion handler to access the `URL` or the `UIImage` once you are done. 

*Video Viewing*

Note: When I say 2D and 3D, I am talking about the type of viewer. `2D = AVPlayer` and `3D = SCNNode / ARKit`.

2D Video: 
```
//You need to create an AVVideoComposition that removes the green pixels using a ChromaKey
let composition = AVMutableVideoComposition(asset: asset) { (request) in
    let source = request.sourceImage.clampedToExtent()
    let filteredImage = RealtimeDepthMaskViewController.filteredImage(ciimage: source)!.clamped(to: source.extent)
    request.finish(with: filteredImage, context: nil)
}

let url = URL(string: "Wherever you store the video")
let asset = AVURLAsset(url: url)
let playerItem = AVPlayerItem(asset: asset)
playerItem.videoComposition = composition
```

2D Image: just get the image of wherever you stored. It should be a black background since an `AVPlayer` cannot see alpha channel, although the alpha channel for specific pixels is `0.0`.

3D Video: 

```
let scene = SKScene(size: videoNode.size)
//Add videoNode to scene
scene.addChild(videoNode)

let chromaKeyMaterial = RealtimeDepthMaskViewController.get3DChromaKey()
chromaKeyMaterial.diffuse.contents = scene
node.geometry!.materials = [chromaKeyMaterial]
```

3D Image: just get the image of wherever you stored. It should be a clear background since in `ARKit` the `SCNNode` can see alpha channels.
