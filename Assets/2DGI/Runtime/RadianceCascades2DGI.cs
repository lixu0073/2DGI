using System.Collections;
using System.Collections.Generic;
using UnityEditor;
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

public class RadianceCascades2DGI : ScriptableRendererFeature
{
    [SerializeField] private LayerMask lightSourceLayerMask;

    [SerializeField] private Material screenUVMat;
    [SerializeField] private Material jumpFloodMat;
    [SerializeField] private Material distanceFieldMat;
    [SerializeField] private Material giMat;
    [SerializeField] private Material blitterMat;
    [SerializeField] private Material temporalAccumulationMat;//时域混合
    [SerializeField] private Material denoiserMat;//降噪
    [SerializeField] private Material separableGaussianBlurMat;//分离近似高斯模糊

    RC2DGIPass rc2dgiPass;
    public override void Create()
    {
        if (lightSourceLayerMask.value < 0)
        {
            Debug.LogError("2DGI:渲染目标Layer缺失，跳过渲染！");
            return;
        }

        if (screenUVMat == null || jumpFloodMat == null || distanceFieldMat == null || giMat == null || blitterMat == null || temporalAccumulationMat == null || denoiserMat == null || separableGaussianBlurMat == null)
        {
            Debug.LogError("2DGI:渲染材质缺失，跳过渲染！");
            return;
        }

        rc2dgiPass = new RC2DGIPass(lightSourceLayerMask, screenUVMat, jumpFloodMat, distanceFieldMat, giMat, blitterMat, temporalAccumulationMat, denoiserMat, separableGaussianBlurMat);
        rc2dgiPass.renderPassEvent = RenderPassEvent.BeforeRenderingPostProcessing;
    }

    public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
    {
        if (rc2dgiPass == null) return;

        var volume = VolumeManager.instance.stack.GetComponent<RadianceCascades2DGIVolume>();
        if (volume == null || volume.isActive == false)
        {
            return;
        }

        rc2dgiPass.Setup(volume, renderingData.cameraData.cameraTargetDescriptor);
        renderer.EnqueuePass(rc2dgiPass);
    }

    protected override void Dispose(bool disposing)
    {
        rc2dgiPass?.Dispose();
        rc2dgiPass = null;
    }


    class RC2DGIPass : ScriptableRenderPass
    {
        //mat
        private Material screenUVMat;
        private Material jumpFloodMat;//JFA
        private Material distanceFieldMat;
        private Material giMat;
        private Material blitterMat;
        private Material temporalAccumulationMat;//用于时域累积混合的材质
        private Material denoiserMat;//时域累积后的降噪材质
        private Material separableGaussianBlurMat;//距离场模糊

        //volume
        private RadianceCascades2DGIVolume volume;
        private int cascadeCount;
        private float renderScale;
        private float rayRange;

        private Vector2Int cascadeResolution;
        private Vector2 cascadeResolutionCached;


        //RT
        RTHandle colorRT;
        RTHandle distanceRT;

        RTHandle jumpFloodRT1;
        RTHandle jumpFloodRT2;

        RTHandle giRT1;
        RTHandle giRT2;

        private RTHandle accumulatedGITexture1;
        private RTHandle accumulatedGITexture2;
        private bool isAccumulationPingPong = false;//用于交换上面两个RT

        private RTHandle denoiserRT1;
        private RTHandle denoiserRT2;
        private int denoiseIterations = 2; //降噪迭代次数，可以作为参数

        RTHandle finalBlurredDFRT;//模糊后的最终DF


        //flag
        bool jumpFlood1IsFinal = false;
        bool gi1IsFinal = false;
        bool isFirstFrame;
        private Matrix4x4 previousViewProjectionMatrix;
        private Vector2Int lastFrameResolution;//RenderingUtils.ReAllocateIfNeeded会检查RT，时域混合Game窗口切换会被认为是垃圾自动销毁


        //cacche
        private static readonly ProfilingSampler s_DistanceFieldSampler = new ProfilingSampler("Distance Field Texture");
        private static readonly ProfilingSampler s_GITextureSampler = new ProfilingSampler("GI Texture");

        private FilteringSettings filteringSettings;

        private readonly List<ShaderTagId> shaderTagsList = new List<ShaderTagId>()
        {
            new ShaderTagId("SRPDefaultUnlit"),
            new ShaderTagId("UniversalForward"),
            new ShaderTagId("UniversalForwardOnly")
        };

        private static readonly int AspectID = Shader.PropertyToID("_Aspect");
        private static readonly int StepSizeID = Shader.PropertyToID("_StepSize");
        private static readonly int ColorTexID = Shader.PropertyToID("_ColorTex");
        private static readonly int DistanceTexID = Shader.PropertyToID("_DistanceTex");
        private static readonly int RayRangeID = Shader.PropertyToID("_RayRange");
        private static readonly int CascadeCountID = Shader.PropertyToID("_CascadeCount");
        private static readonly int SkyRadianceID = Shader.PropertyToID("_SkyRadiance");
        private static readonly int SkyColorID = Shader.PropertyToID("_SkyColor");
        private static readonly int SunColorID = Shader.PropertyToID("_SunColor");
        private static readonly int SunAngleID = Shader.PropertyToID("_SunAngle");
        private static readonly int CascadeResolutionID = Shader.PropertyToID("_CascadeResolution");
        private static readonly int CascadeLevelID = Shader.PropertyToID("_CascadeLevel");
        private static readonly int GITexID = Shader.PropertyToID("_GITex");
        private static readonly int PreviousGITexID = Shader.PropertyToID("_PreviousGITex");
        private static readonly int BlendFactorID = Shader.PropertyToID("_BlendFactor");
        private static readonly int FrameSeedID = Shader.PropertyToID("_FrameSeed");
        private static readonly int StepWidthID = Shader.PropertyToID("_StepWidth");
        private static readonly int LuminanceThresholdID = Shader.PropertyToID("_LuminanceThreshold");
        private static readonly int BlurDirectionID = Shader.PropertyToID("_BlurDirection");

        public RC2DGIPass(LayerMask lightSourceLayerMask, Material screenUVMat, Material jumpFloodMat, Material distanceFieldMat, Material giMat, Material blitterMat, Material temporalAccumulationMat, Material denoiserMat, Material separableGaussianBlurMat)
        {
            this.screenUVMat = screenUVMat;
            this.jumpFloodMat = jumpFloodMat;
            this.distanceFieldMat = distanceFieldMat;
            this.giMat = giMat;
            this.blitterMat = blitterMat;
            this.temporalAccumulationMat = temporalAccumulationMat;
            this.denoiserMat = denoiserMat;
            this.separableGaussianBlurMat = separableGaussianBlurMat;

            isAccumulationPingPong = false;
            isFirstFrame = true;
            lastFrameResolution = Vector2Int.zero;
            filteringSettings = new FilteringSettings(RenderQueueRange.all, lightSourceLayerMask);
        }
        public void Setup(RadianceCascades2DGIVolume volume, RenderTextureDescriptor cameraTargetDescriptor)
        {
            this.volume = volume;
            cascadeCount = volume.cascadeCount.value;
            renderScale = volume.renderScale.value;
            rayRange = volume.rayRange.value;
            denoiseIterations = volume.denoiseIterations.value;

            //计算级联分辨率
            int cascadeWidth = Mathf.CeilToInt((cameraTargetDescriptor.width * renderScale) / Mathf.Pow(2, cascadeCount)) * (int)Mathf.Pow(2, cascadeCount);
            int cascadeHeight = Mathf.CeilToInt((cameraTargetDescriptor.height * renderScale) / Mathf.Pow(2, cascadeCount)) * (int)Mathf.Pow(2, cascadeCount);
            cascadeResolution = new Vector2Int(cascadeWidth, cascadeHeight);
            cascadeResolutionCached = cascadeResolution;
        }

        public override void OnCameraSetup(CommandBuffer cmd, ref RenderingData renderingData)
        {
            var cameraTargetDesc = renderingData.cameraData.cameraTargetDescriptor;
            cameraTargetDesc.depthBufferBits = 0; //不需要深度缓冲区

            //颜色
            cameraTargetDesc.graphicsFormat = UnityEngine.Experimental.Rendering.GraphicsFormat.R16G16B16A16_SFloat; // ARGBFloat
            RenderingUtils.ReAllocateIfNeeded(ref colorRT, cameraTargetDesc, FilterMode.Point, name: "_2DGI_ColorRT");

            //距离场
            cameraTargetDesc.graphicsFormat = UnityEngine.Experimental.Rendering.GraphicsFormat.R16_SFloat; // RHalf
            RenderingUtils.ReAllocateIfNeeded(ref distanceRT, cameraTargetDesc, FilterMode.Point, name: "_2DGI_DistanceRT");

            //JFA
            cameraTargetDesc.graphicsFormat = UnityEngine.Experimental.Rendering.GraphicsFormat.R16G16_SFloat; // RGHalf
            RenderingUtils.ReAllocateIfNeeded(ref jumpFloodRT1, cameraTargetDesc, FilterMode.Point, name: "_2DGI_JumpFloodRT1");
            RenderingUtils.ReAllocateIfNeeded(ref jumpFloodRT2, cameraTargetDesc, FilterMode.Point, name: "_2DGI_JumpFloodRT2");

            //GI
            var giDesc = cameraTargetDesc;
            giDesc.width = cascadeResolution.x;
            giDesc.height = cascadeResolution.y;
            giDesc.graphicsFormat = UnityEngine.Experimental.Rendering.GraphicsFormat.R16G16B16A16_SFloat; // ARGBHalf
            RenderingUtils.ReAllocateIfNeeded(ref giRT1, giDesc, FilterMode.Bilinear, name: "_2DGI_GITexture1");
            RenderingUtils.ReAllocateIfNeeded(ref giRT2, giDesc, FilterMode.Bilinear, name: "_2DGI_GITexture2");

            //累积纹理
            RenderingUtils.ReAllocateIfNeeded(ref accumulatedGITexture1, giDesc, FilterMode.Bilinear, name: "_2DGI_AccumulatedGI1");
            RenderingUtils.ReAllocateIfNeeded(ref accumulatedGITexture2, giDesc, FilterMode.Bilinear, name: "_2DGI_AccumulatedGI2");
            //累计后降噪
            RenderingUtils.ReAllocateIfNeeded(ref denoiserRT1, giDesc, FilterMode.Bilinear, name: "_2DGI_DenoiserRT1");
            RenderingUtils.ReAllocateIfNeeded(ref denoiserRT2, giDesc, FilterMode.Bilinear, name: "_2DGI_DenoiserRT2");

            ConfigureTarget(colorRT);
            ConfigureClear(ClearFlag.All, Color.clear);
        }

        public override void Configure(CommandBuffer cmd, RenderTextureDescriptor cameraTextureDescriptor)
        {
            //运动矢量
            ConfigureInput(ScriptableRenderPassInput.Motion);
        }

        public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
        {
            if (!volume.isActive.value) return;

            var cameraData = renderingData.cameraData;
            if (cameraData.camera.cameraType != CameraType.Game) return;

            CommandBuffer cmd = CommandBufferPool.Get();
            var cameraTargetDesc = cameraData.cameraTargetDescriptor;
            var cameraTarget = cameraData.renderer.cameraColorTargetHandle;
            Vector2 screen = new Vector2(cameraTargetDesc.width, cameraTargetDesc.height);


            var lightSourceDrawingSettings = CreateDrawingSettings(shaderTagsList, ref renderingData, SortingCriteria.CommonTransparent);
            context.DrawRenderers(renderingData.cullResults, ref lightSourceDrawingSettings, ref filteringSettings);


            //=================================
            //============== DF JFA ===========
            //=================================
            using (new ProfilingScope(cmd, s_DistanceFieldSampler))
            {
                cmd.SetGlobalFloat(LuminanceThresholdID, 0.1f);
                cmd.SetGlobalVector(AspectID, screen / Mathf.Max(screen.x, screen.y));

                //---JFA(JumpFlood Algorithm)---
                //init rt
                cmd.Blit(colorRT, jumpFloodRT1, screenUVMat);

                //loop
                jumpFlood1IsFinal = true;
                int max = (int)Mathf.Max(screen.x, screen.y);
                int steps = Mathf.CeilToInt(Mathf.Log(max));
                float stepSize = 1;

                for (var n = 0; n < steps; n++)
                {
                    stepSize *= 0.5f;
                    cmd.SetGlobalFloat(StepSizeID, stepSize);

                    BlitJumpFloodRT(cmd, jumpFloodMat);
                }

                RTHandle finalJumpFloodRT = jumpFlood1IsFinal ? jumpFloodRT1 : jumpFloodRT2;
                cmd.Blit(finalJumpFloodRT, distanceRT, distanceFieldMat);

                //DF Blur
                RTHandle horizontalBlurRT = jumpFloodRT1;
                finalBlurredDFRT = jumpFloodRT2;

                // Pass 1: 水平模糊
                separableGaussianBlurMat.SetVector(BlurDirectionID, new Vector2(1, 0));
                cmd.Blit(distanceRT, horizontalBlurRT, separableGaussianBlurMat);

                // Pass 2: 垂直模糊
                separableGaussianBlurMat.SetVector(BlurDirectionID, new Vector2(0, 1));
                cmd.Blit(horizontalBlurRT, finalBlurredDFRT, separableGaussianBlurMat);

                giMat.SetTexture(DistanceTexID, finalBlurredDFRT);
                denoiserMat.SetTexture(DistanceTexID, finalBlurredDFRT);
                blitterMat.SetTexture(DistanceTexID, finalBlurredDFRT);
            }

            //=================================
            //============== GI ===============
            //=================================
            using (new ProfilingScope(cmd, s_GITextureSampler))
            {
                cmd.SetGlobalTexture(ColorTexID, colorRT);
                cmd.SetGlobalTexture(DistanceTexID, finalBlurredDFRT);
                cmd.SetGlobalFloat(RayRangeID, (screen / Mathf.Min(screen.x, screen.y)).magnitude * rayRange);
                cmd.SetGlobalInt(CascadeCountID, cascadeCount);
                cmd.SetGlobalFloat(SkyRadianceID, volume.skyRadiance.value ? 1 : 0);
                cmd.SetGlobalColor(SkyColorID, volume.skyColor.value);
                cmd.SetGlobalColor(SunColorID, volume.sunColor.value);
                cmd.SetGlobalFloat(SunAngleID, volume.sunAngle.value);
                cmd.SetGlobalVector(CascadeResolutionID, (Vector2)cascadeResolution);
                cmd.SetGlobalFloat(FrameSeedID, (float)Time.frameCount);

                //---GI---
                //loop
                gi1IsFinal = false;

                for (int i = cascadeCount - 1; i >= 0; i--)
                {
                    cmd.SetGlobalInt(CascadeLevelID, i);

                    BlitGiRT(cmd, giMat);
                }

                //---时域累计---
                // 循环结束后，当前帧的“原始”GI结果在 giRT1 或 giRT2 中
                RTHandle rawGITexture = gi1IsFinal ? giRT1 : giRT2;

                //时域混合
                Matrix4x4 currentViewProjectionMatrix = cameraData.GetProjectionMatrix() * cameraData.GetViewMatrix();
                float blendFactor = volume.temporalBlendFactor.value;
                bool resolutionChanged = cameraTargetDesc.width != lastFrameResolution.x || cameraTargetDesc.height != lastFrameResolution.y;
                if (isFirstFrame || currentViewProjectionMatrix != previousViewProjectionMatrix || resolutionChanged)// 判断是否因相机移动需要重置累积
                {
                    blendFactor = 1.0f;
                    isFirstFrame = false;
                }
                previousViewProjectionMatrix = currentViewProjectionMatrix;
                lastFrameResolution = new Vector2Int(cameraTargetDesc.width, cameraTargetDesc.height);

                RTHandle historyTexture = isAccumulationPingPong ? accumulatedGITexture2 : accumulatedGITexture1;
                RTHandle destinationTexture = isAccumulationPingPong ? accumulatedGITexture1 : accumulatedGITexture2;

                temporalAccumulationMat.SetFloat(BlendFactorID, blendFactor);
                temporalAccumulationMat.SetTexture(PreviousGITexID, historyTexture);

                //混合
                cmd.Blit(rawGITexture, destinationTexture, temporalAccumulationMat);
                isAccumulationPingPong = !isAccumulationPingPong;

                //---时域累计降噪---
                RTHandle noisyGITexture = destinationTexture;

                // 第一次迭代，dest是带噪点的GI图，目标是 denoiserRT1
                bool denoiserPingPong = false;

                //这里需要把场景的颜色和距离场作为引导纹理传进去
                denoiserMat.SetTexture(ColorTexID, colorRT);
                denoiserMat.SetTexture(DistanceTexID, finalBlurredDFRT);

                cmd.SetGlobalFloat(StepWidthID, 1); // 初始步长为1
                cmd.Blit(noisyGITexture, denoiserRT1, denoiserMat);

                // 后续的 Ping-Pong 迭代
                for (int i = 1; i < denoiseIterations; i++)
                {
                    RTHandle source = denoiserPingPong ? denoiserRT2 : denoiserRT1;
                    RTHandle dest = denoiserPingPong ? denoiserRT1 : denoiserRT2;

                    // 步长按2的幂次增加
                    cmd.SetGlobalFloat(StepWidthID, Mathf.Pow(2, i));
                    cmd.Blit(source, dest, denoiserMat);
                    denoiserPingPong = !denoiserPingPong;
                }

                // 循环结束后，最终平滑的GI结果
                RTHandle finalDenoisedGI = denoiserPingPong ? denoiserRT2 : denoiserRT1;

                //---Final Blend---
                cmd.SetGlobalTexture(GITexID, finalDenoisedGI);

                //使用临时的 RT 来blit，避免同时读写
                RTHandle tempBlendRT = jumpFloodRT1;
                cmd.Blit(cameraTarget, tempBlendRT);
                cmd.Blit(tempBlendRT, cameraTarget, blitterMat);
            }

            context.ExecuteCommandBuffer(cmd);
            CommandBufferPool.Release(cmd);
        }

        private void BlitJumpFloodRT(CommandBuffer cmd, Material material)
        {
            if (jumpFlood1IsFinal)
            {
                cmd.Blit(jumpFloodRT1, jumpFloodRT2, material);
            }
            else
            {
                cmd.Blit(jumpFloodRT2, jumpFloodRT1, material);
            }

            jumpFlood1IsFinal = !jumpFlood1IsFinal;
        }

        private void BlitGiRT(CommandBuffer cmd, Material material)
        {
            if (gi1IsFinal)
            {
                cmd.Blit(giRT1, giRT2, material);
            }
            else
            {
                cmd.Blit(giRT2, giRT1, material);
            }

            gi1IsFinal = !gi1IsFinal;
        }

        public void Dispose()
        {
            colorRT?.Release();
            distanceRT?.Release();
            jumpFloodRT1?.Release();
            jumpFloodRT2?.Release();
            giRT1?.Release();
            giRT2?.Release();
            denoiserRT1?.Release();
            denoiserRT2?.Release();
            finalBlurredDFRT?.Release();
        }
    }

}
