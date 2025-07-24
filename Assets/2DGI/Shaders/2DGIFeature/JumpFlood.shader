Shader "Hidden/JumpFlood"
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
                float _StepSize;
                float2 _Aspect;
            CBUFFER_END
            
            Varyings vert(Attributes input)
            {
                Varyings output;
                
                output.positionCS = TransformObjectToHClip(input.positionOS.xyz);
                output.uv = input.uv;
                return output;
            }

            float2 frag(Varyings input) : SV_Target
            {
                float min_dist = 1;
                float2 min_dist_uv = float2(0, 0);

                [unroll]
                for (int y = -1; y <= 1; y ++)
                {
                    [unroll]
                    for (int x = -1; x <= 1; x ++)
                    {
                        float2 peekUV = input.uv + float2(x, y) * _Aspect.yx * _StepSize;

                        float2 peek = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, peekUV).xy;
                        if (all(peek))
                        {
                            float2 dir = peek - input.uv;
                            float dist = dot(dir, dir);
                            if (dist < min_dist)
                            {
                                min_dist = dist;
                                min_dist_uv = peek;
                            }
                        }
                    }
                }

                return min_dist_uv;
            }
            ENDHLSL
        }
    }
}