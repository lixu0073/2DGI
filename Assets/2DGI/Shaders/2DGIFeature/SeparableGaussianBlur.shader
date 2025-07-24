Shader "Hidden/SeparableGaussianBlur"
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

            TEXTURE2D(_MainTex);
            SAMPLER(sampler_MainTex);
            float4 _MainTex_TexelSize;
            
            CBUFFER_START(UnityPerMaterial)
                float2 _BlurDirection;
            CBUFFER_END

            // 5-tap 高斯模糊权重 (中心点, +/-1 像素, +/-2 像素)
            static const float weights[3] = { 0.38774, 0.24477, 0.06136 };

            Varyings vert(Attributes input)
            {
                Varyings output;
                
                output.positionCS = TransformObjectToHClip(input.positionOS.xyz);
                output.uv = input.uv;
                return output;
            }

            float frag(Varyings input) : SV_Target
            {
                float totalDistance = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, input.uv).r * weights[0];
                
                [unroll]
                for (int j = 1; j < 3; j++)
                {
                    // 计算正向和反向的采样UV
                    float2 uv_plus = input.uv + _BlurDirection * _MainTex_TexelSize.xy * j;
                    float2 uv_minus = input.uv - _BlurDirection * _MainTex_TexelSize.xy * j;

                    totalDistance += SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, uv_plus).r * weights[j];
                    totalDistance += SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, uv_minus).r * weights[j];
                }

                return totalDistance;
            }
            ENDHLSL
        }
    }
}