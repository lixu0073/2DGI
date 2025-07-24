Shader "Hidden/Blitter"
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

            TEXTURE2D(_GITex);        SAMPLER(sampler_GITex);
            TEXTURE2D(_MainTex);        SAMPLER(sampler_MainTex);

            // 这是一个标准的、高效的交错渐变噪声函数
            float InterleavedGradientNoise(float2 screenPos)
            {
                float3 magic = float3(0.06711056, 0.00583715, 52.9829189);
                return frac(magic.z * frac(dot(screenPos, magic.xy)));
            }

            Varyings vert(Attributes input)
            {
                Varyings output;
                
                output.positionCS = TransformObjectToHClip(input.positionOS.xyz);
                output.uv = input.uv;
                return output;
            }

            float4 frag(Varyings input) : SV_Target
            {
                float4 color = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, input.uv);
                float3 gi = SAMPLE_TEXTURE2D(_GITex, sampler_GITex, input.uv).rgb;
                float dither = InterleavedGradientNoise(input.positionCS.xy);
                dither = (dither - 0.5) / 255.0;// [0,1] -> [-0.5, 0.5]，再除以 255.0，使其强度正好匹配一个 8-bit 颜色级别
                color.rgb += gi + dither;
                return color;
            }
            ENDHLSL
        }
    }
}