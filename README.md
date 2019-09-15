# DepthCamera
**DepthCamera**

Usage: Record a video or image in a 2D or 3D format. 
How: Reads data buffers in using a `AVCaptureDataOutputSynchronizerDelegate`. If using the 3D environment, it then applies a filter from the depth data. This is the simulated 3D affect. If recording a video, it will asynchronously add images to a video. To achieve this affect, the images are added at an unknown rate. To further explain this, look @ _Video Creation Details_ below. If an image, then it simply records the image. From there, the image or video can be obtained and represented in either a 2D (AVPlayer) format or 3D (ARKit) format. To see how to use each of these, please reference the _Video Viewing_  below. On how to record a video, please reference _Video Recording_ below.
Assumptions: The user has a phone that is capable of using these assets.

_Video Creation Details_

Due to the fact that 

_Video Viewing_

2D: To view the video in 2D, you can record a video
