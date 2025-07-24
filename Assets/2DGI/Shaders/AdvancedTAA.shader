Shader "Hidden/AdvancedTAA"
{
    Properties
    {
        [MainTexture] _MainTex("Source Texture", 2D) = "white" {}
        _HistoryTex("History Texture", 2D) = "white" {}
        
        // TAA 核心参数
        [Header(TAA Settings)]
        [Space(10)]
        _Feedback("Feedback Amount", Range(0.7, 0.99)) = 0.94
        _JitterScale("Jitter Scale", Range(0.1, 2.0)) = 1.0
        _Sharpness("Sharpness", Range(0.5, 2.0)) = 1.0
        _MotionSensitivity("Motion Sensitivity", Range(0.0, 2.0)) = 1.0
        
        // 高级控制
        [Header(Advanced Settings)]
        [Space(10)]
        [Toggle]_UseVarianceClipping("Use Variance Clipping", Float) = 1
        [Toggle]_UseNeighborhoodClamping("Use Neighborhood Clamping", Float) = 1
        [Toggle]_UseYCoCgSpace("Use YCoCg Color Space", Float) = 1
        _ClipBounding("Clip Bounding", Range(0.5, 2.0)) = 1.0
        
        // 调试选项
        [Header(Debug Options)]
        [Space(10)]
        [Toggle]_ShowMotionVectors("Show Motion Vectors", Float) = 0
        [Toggle]_ShowReprojection("Show Reprojection", Float) = 0
        [Toggle]_ShowClipping("Show Clipping", Float) = 0
    }

    SubShader
    {
        Tags { "RenderType" = "Opaque" "RenderPipeline" = "UniversalPipeline"}
        LOD 100
        ZTest Always
        ZWrite Off
        Cull Off
        
        Pass
        {
            Name "TAA Resolve"
            
            HLSLPROGRAM

            #pragma vertex VertexTAA
            #pragma fragment FragTAA
            
            #pragma multi_compile _ _TAA_QUALITY_LOW _TAA_QUALITY_MEDIUM _TAA_QUALITY_HIGH

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareDepthTexture.hlsl"
            #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Common.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/UnityInput.hlsl"

            CBUFFER_START(UnityPerMaterial)
                float3 _TAAParams;  // x=jitterX, y=jitterY, z=feedback
                float4 _MainTex_TexelSize;
            CBUFFER_END


            TEXTURE2D_X(_MainTex);
            SAMPLER(sampler_LinearClamp);
            TEXTURE2D_X(_HistoryTex);
            SAMPLER(sampler_PointClamp);

            struct Attributes
            {
                float4 positionOS   : POSITION;
                float2 texcoord     : TEXCOORD0;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct Varyings
            {
                float4 positionCS   : SV_POSITION;
                float2 uv           : TEXCOORD0;
                UNITY_VERTEX_OUTPUT_STEREO
            };

            // ----------------- 顶点着色器 -----------------
            Varyings VertexTAA(Attributes input)
            {
                Varyings output;
                UNITY_SETUP_INSTANCE_ID(input);
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(output);
                
                output.positionCS = TransformObjectToHClip(input.positionOS.xyz);
                output.uv = input.texcoord;
                return output;
            }
            
            // ----------------- 辅助函数 -----------------

            // 更精确的世界坐标重建
            float3 ReconstructWorldPosition(float2 uv, float depth)
            {
                float4 clipPos = float4(uv * 2.0 - 1.0, depth, 1.0);
                #if UNITY_UV_STARTS_AT_TOP
                    clipPos.y = -clipPos.y;
                #endif
                float4 worldPos = mul(UNITY_MATRIX_I_VP, clipPos);
                return worldPos.xyz / worldPos.w;
            }

            // 改进的历史帧UV重投影
            float2 GetHistoryUV(float2 uv)
            {
                float depth = SampleSceneDepth(uv);
                float3 worldPos = ReconstructWorldPosition(uv, depth);
                
                // 使用非抖动VP矩阵重建前一帧位置
                float4 prevClipPos = mul(_PrevViewProjMatrix, float4(worldPos, 1.0));
                prevClipPos.xy /= prevClipPos.w;
                
                // 处理翻转和偏移
                float2 historyUV = prevClipPos.xy * 0.5 + 0.5;
                
                // 边界检查
                historyUV = clamp(historyUV, _MainTex_TexelSize.xy, 1.0 - _MainTex_TexelSize.xy);
                return historyUV;
            }

            // 改进的AABB颜色钳制
            float4 ClipAABB(float3 aabbMin, float3 aabbMax, float4 historyColor)
            {
                // 计算包围盒中心和范围
                float3 center = 0.5 * (aabbMax + aabbMin);
                float3 extents = 0.5 * (aabbMax - aabbMin);
                
                // 添加小偏移防止除零
                extents = max(extents, 1e-5);
                
                // 计算历史颜色到中心的向量
                float3 v_clip = historyColor.rgb - center;
                
                // 计算钳制比例
                float3 v_unit = v_clip / extents;
                float max_unit = max(max(abs(v_unit.x), abs(v_unit.y)), abs(v_unit.z));
                
                if (max_unit > 1.0)
                {
                    return float4(center + v_clip / max_unit, historyColor.a);
                }
                return historyColor;
            }

            // 邻域Min/Max计算 (优化版本)
            void GetMinMax(in float2 uv, out float3 colorMin, out float3 colorMax)
            {
                float2 texelSize = _MainTex_TexelSize.xy;
                float3 center = SAMPLE_TEXTURE2D_X(_MainTex, sampler_LinearClamp, uv).rgb;
                
                #if defined(_TAA_QUALITY_HIGH) // 3x3
                    colorMin = center;
                    colorMax = center;
                    
                    UNITY_UNROLL
                    for(int y = -1; y <= 1; y++)
                    {
                        UNITY_UNROLL
                        for(int x = -1; x <= 1; x++)
                        {
                            if (x == 0 && y == 0) continue;
                            float2 sampleUV = uv + float2(x, y) * texelSize;
                            float3 sampleColor = SAMPLE_TEXTURE2D_X(_MainTex, sampler_LinearClamp, sampleUV).rgb;
                            colorMin = min(colorMin, sampleColor);
                            colorMax = max(colorMax, sampleColor);
                        }
                    }
                #elif defined(_TAA_QUALITY_MEDIUM) // 5点十字
                    float3 s1 = SAMPLE_TEXTURE2D_X(_MainTex, sampler_LinearClamp, uv + float2(1, 0) * texelSize).rgb;
                    float3 s2 = SAMPLE_TEXTURE2D_X(_MainTex, sampler_LinearClamp, uv + float2(-1, 0) * texelSize).rgb;
                    float3 s3 = SAMPLE_TEXTURE2D_X(_MainTex, sampler_LinearClamp, uv + float2(0, 1) * texelSize).rgb;
                    float3 s4 = SAMPLE_TEXTURE2D_X(_MainTex, sampler_LinearClamp, uv + float2(0, -1) * texelSize).rgb;
                    
                    colorMin = min(min(min(min(center, s1), s2), s3), s4);
                    colorMax = max(max(max(max(center, s1), s2), s3), s4);
                #else // _TAA_QUALITY_LOW - 中心点
                    colorMin = colorMax = center;
                #endif
            }

            // ----------------- 片元着色器 -----------------
            float4 FragTAA(Varyings input) : SV_Target
            {
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);
                
                // 移除当前帧的Jitter，获取"标准"UV
                float2 uv = input.uv;
                float2 unjitteredUV = uv - _TAAParams.xy;
                
                // 采样当前帧颜色
                float4 currentColor = SAMPLE_TEXTURE2D_X(_MainTex, sampler_LinearClamp, unjitteredUV);
                
                // 计算历史帧UV
                float2 historyUV = GetHistoryUV(unjitteredUV);
                
                // 采样历史帧颜色
                float4 historyColor = SAMPLE_TEXTURE2D_X(_HistoryTex, sampler_PointClamp, historyUV);
                
                // 构建邻域包围盒并进行钳制
                float3 colorMin, colorMax;
                GetMinMax(unjitteredUV, colorMin, colorMax);
                historyColor = ClipAABB(colorMin, colorMax, historyColor);
                
                // 混合当前帧和历史帧
                return lerp(currentColor, historyColor, _TAAParams.z);
            }

            ENDHLSL
        }
    }
}