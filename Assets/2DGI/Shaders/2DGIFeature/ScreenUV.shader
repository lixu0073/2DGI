Shader "Hidden/ScreenUV"
{
    Properties
    {
        _MainTex ("Texture", 2D) = "white" {}
        _LuminanceThreshold ("Luminance Threshold", Range(0, 1)) = 0.2
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

            CBUFFER_START(UnityPerMaterial)
                float _LuminanceThreshold;
            CBUFFER_END

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
                float alpha = color.a;
                float luminance = dot(color.rgb, float3(0.2126, 0.7152, 0.0722));

                float alphaMask = step(0.5, color.a);
                float isBrightMask = step(_LuminanceThreshold, luminance);
                //像素是否是纯黑 (是遮挡物？)  step(0.01, luminance) 在 luminance >= 0.01 时为 1，所以 1.0 - ... 可以在 luminance < 0.01 时为 1
                float isDarkMask = 1.0 - step(0.1, luminance); 
                float featureMask = max(isBrightMask, isDarkMask);
                float finalMask = alphaMask * featureMask;
                float2 seedUV = lerp(float2(-1.0, -1.0), input.uv, finalMask);

                // float alpha = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, input.uv).a;
                // float mask = step(0.5, alpha);
                // float2 seedUV = lerp(float2(-1.0, -1.0), input.uv, mask);
                    
                return float4(seedUV, 0, 1);

                //return input.uv * (1 - step(alpha, 0.5));
            }
            ENDHLSL
        }
    }
}