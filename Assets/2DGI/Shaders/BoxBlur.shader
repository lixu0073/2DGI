Shader "Hidden/BoxBlur"
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

            TEXTURE2D(_MainTex);        SAMPLER(sampler_MainTex);
            float4 _MainTex_TexelSize;

            Varyings vert(Attributes input)
            {
                Varyings output;
                
                output.positionCS = TransformObjectToHClip(input.positionOS.xyz);
                output.uv = input.uv;
                return output;
            }

            float frag(Varyings input) : SV_Target
            {
                // 3x3 均值模糊
                float totalDistance = 0.0;
                
                [unroll]
                for (int x = -1; x <= 1; x++)
                {
                    [unroll]
                    for (int y = -1; y <= 1; y++)
                    {
                        float2 offset = float2(x, y) * _MainTex_TexelSize.xy;
                        totalDistance += SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, input.uv + offset).r;
                    }
                }

                return totalDistance / 9.0;
            }
            ENDHLSL
        }
    }
}