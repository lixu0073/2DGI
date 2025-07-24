Shader "Hidden/ATrousDenoiser"
{
    Properties
    {
        _MainTex ("Input", 2D) = "white" {}
        _ColorTex("Edge Guide (Color)", 2D) = "white" {}
        _DistanceTex("Edge Guide (Distance)", 2D) = "white" {}
    }
    SubShader
    {
        Pass
        {
            Cull Off ZWrite Off ZTest Always

            HLSLPROGRAM

            #pragma vertex vert
            #pragma fragment frag

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

            TEXTURE2D(_MainTex);        SAMPLER(sampler_MainTex);
            TEXTURE2D(_ColorTex);       SAMPLER(sampler_ColorTex);
            TEXTURE2D(_DistanceTex);    SAMPLER(sampler_DistanceTex);

            float4 _MainTex_TexelSize;
            float _StepWidth;
            
            // Sigma值越小，边缘保护越强，模糊效果越弱
            static const float KERNEL_SIGMA_COLOR = 0.125;
            static const float KERNEL_SIGMA_DISTANCE = 0.0125;

            struct Attributes
            {
                float4 positionOS   : POSITION;
                float2 uv           : TEXCOORD0;
            };

            struct Varyings
            {
                float4 positionCS   : SV_POSITION;
                float2 uv           : TEXCOORD0;
            };

            Varyings vert(Attributes input)
            {
                Varyings output;
                output.positionCS = TransformObjectToHClip(input.positionOS.xyz);
                output.uv = input.uv;
                return output;
            }

            float4 frag(Varyings i) : SV_Target
            {
                float4 centerColor = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, i.uv);
                float3 centerEdgeColor = SAMPLE_TEXTURE2D(_ColorTex, sampler_ColorTex, i.uv).rgb;
                float centerEdgeDist = SAMPLE_TEXTURE2D(_DistanceTex, sampler_DistanceTex, i.uv).r;

                // [新增] 计算中心点的亮度 (Luminance)
                float centerLuma = dot(centerColor.rgb, float3(0.2126, 0.7152, 0.0722));

                float4 accumulatedColor = centerColor;
                float totalWeight = 1.0;

                // [新增] Luma Sigma，用于控制对光照变化的敏感度，建议作为 Volume 参数
                const float KERNEL_SIGMA_LUMA = 0.2;

                [unroll]
                for (int x = -2; x <= 2; x++)
                {
                    [unroll]
                    for (int y = -2; y <= 2; y++)
                    {
                        if (x == 0 && y == 0) continue;
                        
                        float2 offset = float2(x, y);
                        float2 sampleUV = i.uv + offset * _MainTex_TexelSize.xy * _StepWidth;

                        if (sampleUV.x >= 0.0 && sampleUV.x <= 1.0 && sampleUV.y >= 0.0 && sampleUV.y <= 1.0)
                        {
                            float4 sampleColor = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, sampleUV);
                            float3 sampleEdgeColor = SAMPLE_TEXTURE2D(_ColorTex, sampler_ColorTex, sampleUV).rgb;
                            float sampleEdgeDist = SAMPLE_TEXTURE2D(_DistanceTex, sampler_DistanceTex, sampleUV).r;

                            //计算采样点的亮度
                            float sampleLuma = dot(sampleColor.rgb, float3(0.2126, 0.7152, 0.0722));

                            //---边缘感知权重计算 (三重权重)---
                            float colorDiff = distance(centerEdgeColor, sampleEdgeColor);
                            float colorWeight = exp(-(colorDiff * colorDiff) / (2.0 * KERNEL_SIGMA_COLOR * KERNEL_SIGMA_COLOR));

                            float distDiff = abs(centerEdgeDist - sampleEdgeDist);
                            float distWeight = exp(-(distDiff * distDiff) / (2.0 * KERNEL_SIGMA_DISTANCE * KERNEL_SIGMA_DISTANCE));

                            //基于亮度的权重
                            float lumaDiff = abs(centerLuma - sampleLuma);
                            float lumaWeight = exp(-(lumaDiff * lumaDiff) / (2.0 * KERNEL_SIGMA_LUMA * KERNEL_SIGMA_LUMA));

                            //最终权重
                            float finalWeight = colorWeight * distWeight * lumaWeight;

                            accumulatedColor += sampleColor * finalWeight;
                            totalWeight += finalWeight;
                        }
                    }
                }

                return accumulatedColor / totalWeight;
            }
            ENDHLSL
        }
    }
}