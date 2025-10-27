#include "reshade.fxh"

// === ПАРАМЕТРЫ ===

uniform float pre_boost <
    ui_label = "Предусиление яркости";
    ui_tooltip = "Усиление яркости до ослабления маской";
    ui_type = "slider";
    ui_min = 1.0;
    ui_max = 3.0;
    ui_step = 0.1;
> = 3.0;

uniform float mask_step <
    ui_label = "Шаг маски";
    ui_tooltip = "Расстояние между точками триады (в пикселях)";
    ui_type = "slider";
    ui_min = 0.5;
    ui_max = 3.0;
    ui_step = 0.1;
> = 0.8;

uniform float intra_blur <
    ui_label = "Внутрипиксельное размытие";
    ui_tooltip = "Сила влияния цветов внутри пикселя (каналы смешиваются)";
    ui_type = "slider";
    ui_min = 0.0;
    ui_max = 2.0;
    ui_step = 0.01;
> = 0.27;

uniform float inter_blur <
    ui_label = "Межпиксельное размытие";
    ui_tooltip = "Сила влияния соседних пикселей";
    ui_type = "slider";
    ui_min = 0.1;
    ui_max = 1.5;
    ui_step = 0.001;
> = 0.626;

uniform float mask_brightness_loss <
    ui_label = "Потери в маске";
    ui_tooltip = "Коэффициент потерь яркости в теневой маске (применяется ко всему цвету)";
    ui_type = "slider";
    ui_min = 0.5;
    ui_max = 0.8;
    ui_step = 0.01;
> = 0.65;

uniform float crt_gamma <
    ui_label = "Гамма CRT";
    ui_tooltip = "Типичная гамма CRT-монитора (2.2–2.5)";
    ui_type = "slider";
    ui_min = 0.8;
    ui_max = 2.8;
    ui_step = 0.05;
> = 0.9;

uniform float persistence <
    ui_label = "Послесвечение (Persistence)";
    ui_tooltip = "Сила фосфорного послесвечения (0 = выкл)";
    ui_type = "slider";
    ui_min = 0.0;
    ui_max = 0.99;
    ui_step = 0.01;
> = 0.99;

// === ТЕКСТУРЫ И СЭМПЛЕРЫ ===

texture2D sourceTexture : COLOR;

// Промежуточный буфер после внутрипиксельного влияния
texture2D intraInfluenceTexture { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA16F; };

// Буфер для хранения предыдущего кадра (для послесвечения)
texture2D persistenceBuffer { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA16F; };

// Финальный CRT-выход до гаммы и persistence-смешивания
texture2D crtOutputTexture { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA16F; };

sampler2D sourceSampler { Texture = sourceTexture; };
sampler2D intraInfluenceSampler { Texture = intraInfluenceTexture; };
sampler2D persistenceSampler { Texture = persistenceBuffer; };
sampler2D crtOutputSampler { Texture = crtOutputTexture; };

// === ВНУТРИПИКСЕЛЬНОЕ ВЛИЯНИЕ ===
// Примечание: это художественное приближение.
// Мы смещаемся к "позициям" R, G, B субпикселей и берём соответствующие каналы.
// В реальности изображение не содержит физических субпикселей — это стилизация.

float3 calculateIntraPixelInfluence(float2 texcoord, float2 texsize, float3 baseColor)
{
    float2 pixelSize = 1.0 / texsize;

    // Позиции субпикселей в UV (смещение в пикселях → UV)
    float2 r_uv = float2(0.0, 0.0);
    float2 g_uv = float2(mask_step * pixelSize.x, 0.0);
    float2 b_uv = float2(0.5 * mask_step * pixelSize.x, 0.866 * mask_step * pixelSize.y);

    // Берём цвета в этих точках
    float r = tex2D(sourceSampler, texcoord + r_uv).r;
    float g = tex2D(sourceSampler, texcoord + g_uv).g;
    float b = tex2D(sourceSampler, texcoord + b_uv).b;

    // Расстояния между субпикселями (в пикселях)
    float d_rg = mask_step;                    // R–G горизонтально
    float d_rb = mask_step;                    // в равностороннем треугольнике все стороны = mask_step
    float d_gb = mask_step;

    // Сигма — теперь в пикселях (intra_blur = 0.0…2.0)
    float sigma = max(intra_blur, 0.001);

    float w_rg = exp(-(d_rg * d_rg) / (2.0 * sigma * sigma));
    float w_rb = exp(-(d_rb * d_rb) / (2.0 * sigma * sigma));
    float w_gb = exp(-(d_gb * d_gb) / (2.0 * sigma * sigma));

    float3 result;
    result.r = r + g * w_rg + b * w_rb;
    result.g = g + r * w_rg + b * w_gb;
    result.b = b + r * w_rb + g * w_gb;

    return saturate(result);
}

// === ГАУССОВО РАЗМЫТИЕ (МЕЖПИКСЕЛЬНОЕ) ===

float3 gaussianBlur(float2 texcoord, float2 texsize, float sigma)
{
    float3 sum = 0.0;
    float weight_sum = 0.0;
    const int kernelSize = 3; // 7x7 ядро

    for (int x = -kernelSize; x <= kernelSize; x++)
    {
        for (int y = -kernelSize; y <= kernelSize; y++)
        {
            float2 offset = float2(x, y) / texsize;
            float3 sampleColor = tex2D(intraInfluenceSampler, texcoord + offset).rgb;
            float distance = sqrt(float(x * x + y * y)); // расстояние в пикселях
            float weight = exp(-(distance * distance) / (2.0 * sigma * sigma));
            sum += sampleColor * weight;
            weight_sum += weight;
        }
    }

    return (weight_sum > 0.0) ? sum / weight_sum : sum;
}

// === ПРОХОД 1: Внутрипиксельное влияние + ослабление маски ===

float4 Pass1_PS(float4 pos : SV_Position, float2 texcoord : TEXCOORD0) : SV_Target
{
    float2 texsize = float2(BUFFER_WIDTH, BUFFER_HEIGHT);
    float3 baseColor = tex2D(sourceSampler, texcoord).rgb;
    float3 intraColor = calculateIntraPixelInfluence(texcoord, texsize, baseColor);
    float3 finalColor = intraColor * (1.0 - mask_brightness_loss) * pre_boost;
    return float4(saturate(finalColor), 1.0);
}

// === ПРОХОД 2: Межпиксельное размытие → crtOutputTexture ===

float4 Pass2_PS(float4 pos : SV_Position, float2 texcoord : TEXCOORD0) : SV_Target
{
    float2 texsize = float2(BUFFER_WIDTH, BUFFER_HEIGHT);
    float sigma_inter = inter_blur * 0.5;
    float3 blurred = gaussianBlur(texcoord, texsize, sigma_inter);
    return float4(saturate(blurred), 1.0);
}

// === ПРОХОД 3: Обновление буфера послесвечения (сохраняем ДО гаммы!) ===

float4 Pass3_UpdatePersistence(float4 pos : SV_Position, float2 texcoord : TEXCOORD0) : SV_Target
{
    float3 current = tex2D(crtOutputSampler, texcoord).rgb;
    return float4(current, 1.0);
}

// === ПРОХОД 4: Финальный вывод с послесвечением и гаммой ===

float4 Pass4_FinalOutput(float4 pos : SV_Position, float2 texcoord : TEXCOORD0) : SV_Target
{
    float3 current = tex2D(crtOutputSampler, texcoord).rgb;
    float3 previous = tex2D(persistenceSampler, texcoord).rgb;

    // Смешиваем с предыдущим кадром (послесвечение)
    float3 persistent = lerp(current, previous, persistence);

    // Применяем CRT-гамму только здесь
    float3 final = pow(saturate(persistent), 1.0 / crt_gamma); // ← ИСПРАВЛЕНО: гамма = 1/gamma!

    return float4(final, 1.0);
}

// === ТЕХНИКА ===

technique CRT_Effect
{
    pass IntraPixelInfluence
    {
        VertexShader = PostProcessVS;
        PixelShader = Pass1_PS;
        RenderTarget = intraInfluenceTexture;
    }
    pass InterPixelInfluence
    {
        VertexShader = PostProcessVS;
        PixelShader = Pass2_PS;
        RenderTarget = crtOutputTexture;
    }
    pass UpdatePersistence
    {
        VertexShader = PostProcessVS;
        PixelShader = Pass3_UpdatePersistence;
        RenderTarget = persistenceBuffer;
    }
    pass GammaAndOutput
    {
        VertexShader = PostProcessVS;
        PixelShader = Pass4_FinalOutput;
        // Рендер в бэкбуфер (по умолчанию)
    }
}