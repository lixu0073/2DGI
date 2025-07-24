Shader "Hidden/TemporalAccumulation"
{
    Properties
    {
        _MainTex ("Current Frame GI", 2D) = "white" {} // 当前帧计算出的原始GI
        _PreviousGITex ("Previous Frame Accumulated GI", 2D) = "black" {} // 上一帧累积后的GI
        _BlendFactor ("Blend Factor", Range(0.0, 1.0)) = 0.1 // 混合系数
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

            TEXTURE2D(_MainTex);                        SAMPLER(sampler_MainTex);
            TEXTURE2D(_PreviousGITex);                  SAMPLER(sampler_PreviousGITex);
            float4 _PreviousGITex_TexelSize;
            TEXTURE2D(_CameraMotionVectorsTexture);     SAMPLER(sampler_CameraMotionVectorsTexture);

            CBUFFER_START(UnityPerMaterial)
                float _BlendFactor;
            CBUFFER_END 
            
            Varyings vert(Attributes input)
            {
                Varyings output;
                output.positionCS = TransformObjectToHClip(input.positionOS.xyz);
                output.uv = input.uv;
                return output;
            }

            float4 frag(Varyings i) : SV_Target
            {
                float4 currentGI = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, i.uv);  
                float4 previousGI = SAMPLE_TEXTURE2D(_PreviousGITex, sampler_PreviousGITex, i.uv);

                float3 colorMin = previousGI.rgb;
                float3 colorMax = previousGI.rgb;

                [unroll]
                for (int y = -1; y <= 1; y++)
                {
                    [unroll]
                    for (int x = -1; x <= 1; x++)
                    {
                        if (x == 0 && y == 0) continue;
                        
                        float2 offset = float2(x, y) * _PreviousGITex_TexelSize.xy;
                        float3 neighborColor = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, i.uv + offset).rgb;
                        //float3 neighborColor = SAMPLE_TEXTURE2D(_PreviousGITex, sampler_PreviousGITex, i.uv + offset).rgb;
                        
                        colorMin = min(colorMin, neighborColor);
                        colorMax = max(colorMax, neighborColor);
                    }
                }

                // colorMin = min(colorMin, currentGI);
                // colorMax = max(colorMax, currentGI);

                previousGI.rgb = clamp(previousGI.rgb, colorMin, colorMax);
                //_BlendFactor 越小，历史帧保留越多，画面越稳定
                return lerp(previousGI, currentGI, max(0.05,_BlendFactor));
            }
            ENDHLSL
        }
    }
}