Shader "Hidden/DistanceField"
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

            CBUFFER_START(UnityPerMaterial)
                float2 _Aspect;
            CBUFFER_END

            Varyings vert(Attributes input)
            {
                Varyings output;
                
                output.positionCS = TransformObjectToHClip(input.positionOS.xyz);
                output.uv = input.uv;
                return output;
            }

            half frag(Varyings input) : SV_Target
            {
                half2 jf = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, input.uv).rg;
                if(jf.x < 0.0h)
                {
                    return 1.0h;
                }

                return distance(input.uv, jf);
            }

            ENDHLSL
        }
    }
}