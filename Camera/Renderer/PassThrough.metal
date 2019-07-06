//
//  PassThrough.metal
//
//  Created by Bradley French on 7/3/19.
//  Copyright © 2019 Bradley French. All rights reserved.
//

#include <metal_stdlib>
using namespace metal;

typedef struct {
    float2 position [[ attribute(0) ]];
    float2 texCoord [[ attribute(1) ]];
} Vertex;

typedef struct {
    float4 position [[ position ]];
    float2 texCoord;
} ColorInOut;

vertex ColorInOut passThroughVertex(Vertex in [[ stage_in ]])
{
    ColorInOut out;
    out.position = float4(in.position, 0.0, 1.0);
    out.texCoord = in.texCoord;
    return out;
}

fragment float4 passThroughFragment(ColorInOut       in      [[ stage_in ]],
                                    texture2d<float> texture [[ texture(0) ]])
{
    constexpr sampler colorSampler;
    float4 color = texture.sample(colorSampler, in.texCoord);
    return color;
}

