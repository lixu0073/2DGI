Shader "Hidden/2DGI"
{
    Properties
    {
        _MainTex ("Texture", 2D) = "white" {}
    }
    SubShader
    {
        Pass
        {
            Cull Off
            ZWrite Off
            ZTest Always

            HLSLPROGRAM
            
            #pragma vertex vert
            #pragma fragment frag
            
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

            #define PI2 6.28318530718

            struct Attributes
            {
                float4 positionOS   : POSITION;
                float2 uv           : TEXCOORD0;
            };

            struct Varyings
            {
                float2 uv           : TEXCOORD0;
                float4 positionCS   : SV_POSITION;
            };

            TEXTURE2D(_MainTex);        SAMPLER(sampler_MainTex);
            TEXTURE2D(_ColorTex);       SAMPLER(sampler_ColorTex);
            TEXTURE2D(_DistanceTex);    SAMPLER(sampler_DistanceTex);
            TEXTURE2D(_PreviousGITex);  SAMPLER(sampler_PreviousGITex);
            TEXTURE2D(_BlueNoiseTexture);   SAMPLER(sampler_BlueNoiseTexture);
            float4 _BlueNoiseTexture_TexelSize;

            CBUFFER_START(UnityPerMaterial)
                float2 _Aspect;
                float _RayRange;

                float2 _CascadeResolution;
                uint _CascadeLevel;
                uint _CascadeCount;

                float _SkyRadiance;
                float3 _SkyColor;
                float3 _SunColor;
                float _SunAngle;

                float _FrameSeed; 
            CBUFFER_END

            Varyings vert(Attributes input)
            {
                Varyings output;
                
                output.positionCS = TransformObjectToHClip(input.positionOS.xyz);
                output.uv = input.uv;
                return output;
            }
            
            inline float2 CalculateRayRange(uint index, uint count)
            {
                //使用位运算来计算范围代替 pow
                //The values returned : 0, 3, 15, 63, 255
                //Dividing by 3       : 0, 1, 5, 21, 85
                //and the distance between each value is multiplied by 4 each time

                float maxValue = (1 << (count*2)) - 1;
                float start = (1 << (index*2)) - 1;
                float end = (1 << (index*2 + 2)) - 1;

                float2 r = float2(start, end) / maxValue;
                return r * _RayRange;
            }

            //对天空和太阳进行积分，计算特定角度范围内的平均光照。
            inline float3 SampleSkyRadiance(float a0, float a1) 
            {
                // Sky integral formula taken from "Analytic Direct Illumination" - Mathis
                // https://www.shadertoy.com/view/NttSW7
                const float3 SkyColor = _SkyColor;
                const float3 SunColor = _SunColor;
                const float SunA = _SunAngle;
                const float SSunS = 8.0;
                const float ISSunS = 1/SSunS;
                float3 SI = SkyColor*(a1-a0-0.5*(cos(a1)-cos(a0)));
                SI += SunColor*(atan(SSunS*(SunA-a0))-atan(SSunS*(SunA-a1)))*ISSunS;
                return SI * 0.16;//SI * (1.0 / PI2);
            }

            //Raymarching
            inline float4 SampleRadianceSDF(float2 rayOrigin, float2 rayDirection, float2 rayRange)
            {
                float t = rayRange.x + 0.001;//给光线一个微小的初始步进，防止它立刻“击中”自己所在的表面
                float4 hit = float4(0, 0, 0, 1);
                float minHitDistance = 1e9;

                for (int i = 0; i < 32; i++)
                {
                    //计算当前光线位置，并用Aspect校正
                    float2 currentPosition = rayOrigin + t * rayDirection * _Aspect.yx;

                    if (t > rayRange.y || currentPosition.x < 0 || currentPosition.y < 0 || currentPosition.x > 1 || currentPosition.y > 1)
                    {
                        float4 hit = float4(0, 0, 0, 0);
                        break;
                    }

                    float distance = SAMPLE_TEXTURE2D(_DistanceTex, sampler_DistanceTex, currentPosition).r;
                    minHitDistance = min(minHitDistance, distance);


                    //命中，采样颜色，并将alpha设为0表示命中
                    if (distance < 0.001)
                    {
                        float3 surfaceColor = SAMPLE_TEXTURE2D(_ColorTex, sampler_ColorTex, currentPosition).rgb;
                        // 采样该命中点在上一帧的GI颜色
                        float3 previousIndirectLight = SAMPLE_TEXTURE2D(_PreviousGITex, sampler_PreviousGITex, currentPosition).rgb;


                        float indirectLuminance = dot(previousIndirectLight, float3(0.2126, 0.7152, 0.0722));
                        float3 saturatedIndirect = float3(indirectLuminance, indirectLuminance, indirectLuminance);
                        previousIndirectLight = lerp(previousIndirectLight, saturatedIndirect, -0.5);
                        // 将表面颜色与它接收到的间接光照相乘，模拟二次反弹
                        float3 finalColor = surfaceColor * (previousIndirectLight + 0.3);//0.3 ambient indrect

                        hit = float4(finalColor, 0);// alpha为0表示命中
                        break;
                    }

                    //未命中，步进
                    t += distance * 0.9;//* 0.9 保守递进 避免穿墙
                }
    
                float occlusion = smoothstep(0, 0.005, minHitDistance); // 0.002 是遮蔽半径，可调
                hit.a = occlusion;

                return hit;
            }

            inline float random(float2 p) 
            { 
                return frac(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453); 
            }

            float4 frag(Varyings input) : SV_Target
            {
                //计算当前片元所属的块(Block)索引
                float2 pixelIndex = floor(input.uv * _CascadeResolution);
    
                uint blockSqrtCount = 1 << _CascadeLevel;//pow(2, _CascadeLevel)
    
                float2 blockDim = _CascadeResolution / blockSqrtCount;
                float2 block2DIndex = floor(pixelIndex / blockDim);
                float blockIndex = block2DIndex.x + block2DIndex.y * blockSqrtCount;
    
                float2 coordsInBlock = fmod(pixelIndex, blockDim);
    
                float4 finalResult = 0;
                //计算光线范围
                float2 rayOrigin = (coordsInBlock + 0.5) * blockSqrtCount;
                float2 rayRange = CalculateRayRange(_CascadeLevel, _CascadeCount);
    
                [unroll]
                for (int i = 0; i < 4; i++)
                {
                    //计算光线的角度，确保所有块发射的光线能均匀覆盖360度
                    float angleStep = PI2 / (blockSqrtCount * blockSqrtCount * 4);
                    float angleIndex = blockIndex * 4 + i;

                    //蓝噪声随机角度采样
                    float2 noiseUV = pixelIndex * _BlueNoiseTexture_TexelSize.xy;
                    float blueNoiseOffset = SAMPLE_TEXTURE2D(_BlueNoiseTexture, sampler_BlueNoiseTexture, noiseUV).r;

                    float temporalOffset = frac(_FrameSeed * 0.61803398875);
                    float finalRandomOffset = frac(blueNoiseOffset + temporalOffset);

                    float angle = (angleIndex + finalRandomOffset) * angleStep;
    
                    float2 rayDirection = float2(cos(angle), sin(angle));
                    
                    //光线步进
                    float4 radiance = SampleRadianceSDF(rayOrigin / _CascadeResolution, rayDirection, rayRange);
                    
                    //如果alpha不为0，说明光线未命中任何物体，需要从上一级或天空中获取光照
                    if(radiance.a != 0)
                    {
                        if (_CascadeLevel != _CascadeCount - 1)//非顶层级联
                        {
                            //合并上一级联 (_MainTex)
                            float2 position = coordsInBlock * 0.5 + 0.25;
                            float2 positionOffset = float2(fmod(angleIndex, blockSqrtCount * 2), floor(angleIndex / (blockSqrtCount * 2)));//将当前光线方向映射到上一级贴图的对应位置

                            position = clamp(position, 0.5, blockDim * 0.5 - 0.5);
            
                            float4 rad = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex,  (position + positionOffset * blockDim * 0.5) / _CascadeResolution);

                            radiance.rgb += rad.rgb * radiance.a;
                            radiance.a *= rad.a;

                            // radiance.rgb += rad.rgb * radiance.a;
                            // radiance.a = rad.a;
                        }
                        else
                        {
                            //如果是顶层级联，光线直接射向天空，采样天空光
                            float3 sky = SampleSkyRadiance(angle, angle + angleStep) * _SkyRadiance;    
                            radiance.rgb += (sky / angleStep) * 2;
                        }
                    }
                    //累加光线
                    finalResult += radiance * 0.25;
                }

                return finalResult;
            }

            ENDHLSL
        }
    }
}