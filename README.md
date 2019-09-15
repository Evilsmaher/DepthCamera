# DepthCamera
_DepthCamera_

*Add To Your Project*
In your `Podfile` add `pod 'DepthCamera'`.

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

2D: To view the video in 2D, you can record a video using _Video Recording Above_ for 2D. Then, 
