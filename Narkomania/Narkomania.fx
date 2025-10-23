#include "ReShade.fxh"

uniform float particleSize <
    ui_type = "slider"; 
    ui_min = 0.001; 
    ui_max = 1.0; 
    ui_step = 0.001; 
    ui_label = "Particle Size";
    > = 0.001;

uniform float settlingSpeed <
    ui_type = "slider";
    ui_min = 0.001;
    ui_max = 0.1;
    ui_step = 0.001;
    ui_label = "Settling Speed";
    > = 0.1;

uniform float damping <
    ui_type = "slider";
    ui_min = 0.0;
    ui_max = 1.0;
    ui_step = 0.01;
    ui_label = "Damping Factor";
    > = 0.9;

static const int radius = 3;

texture BackBufferTex : COLOR;
sampler BackBuffer { Texture = BackBufferTex; };

uniform float2 texSize = float2(BUFFER_WIDTH, BUFFER_HEIGHT);

float4 PS(float4 pos : SV_POSITION, float2 texcoord : TEXCOORD) : SV_TARGET
{
    float2 uv = texcoord;

    float3 currentColor = tex2D(BackBuffer, uv).rgb;

    int dim = radius * 2 + 1;

    float3 totalChange = float3(0.0, 0.0, 0.0);

    for (int y = -radius; y <= radius; y++)
    {
        for (int x = -radius; x <= radius; x++)
        {
            if (x == 0 && y == 0) continue;

            float2 neighborUV = uv + float2(x, y) / texSize;
            float3 neighborColor = tex2D(BackBuffer, neighborUV).rgb;

            // Разница в "высотах" (количество частиц)
            float3 diff = (currentColor - neighborColor) / particleSize;

            // Перенос частиц с учетом скорости оседания
            float3 transfer = diff * settlingSpeed;

            // Нормализация и ограничение переноса
            transfer = clamp(transfer, -neighborColor, currentColor);

            // Взаимный перенос с учетом затухания и двунаправленности
            float3 netTransfer = transfer - (-diff * settlingSpeed * damping);

            totalChange -= netTransfer;
        }
    }

    float3 finalColor = saturate(currentColor + totalChange);

    return float4(finalColor, 1.0);
}

technique Pesochnica
{
    pass
    {
        VertexShader = PostProcessVS;
        PixelShader = PS;
    }
}
