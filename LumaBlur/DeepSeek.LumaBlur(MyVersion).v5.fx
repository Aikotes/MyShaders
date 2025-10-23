// CRT_Dynamic_Glow.fx
// Reshade 6.1.1
#include "ReShade.fxh"

uniform float mymult = 1.44;

uniform float GlowIntensity <
    ui_type = "slider";
    ui_min = 0.0;
    ui_max = 1.0;
    ui_step = 0.01;
    ui_label = "Glow Intensity";
    ui_tooltip = "Overall strength of the glow effect";
> = 1.0;

uniform float GlowRadius <
    ui_type = "slider";
    ui_min = 0.5;
    ui_max = 100.0;
    ui_step = 0.1;
    ui_label = "Base Glow Radius";
    ui_tooltip = "Base radius for the glow effect";
> = 32.0;

uniform float LumaThreshold <
    ui_type = "slider";
    ui_min = 0.000;
    ui_max = 0.9;
    ui_step = 0.01;
    ui_label = "Luminance Threshold";
    ui_tooltip = "Brightness level where glow starts to appear";
> = 0.0;

uniform float BlurSharpness <
    ui_type = "slider";
    ui_min = 0.001;
    ui_max = 8.0;
    ui_step = 0.1;
    ui_label = "Blur Sharpness";
    ui_tooltip = "Higher values preserve more details in dark areas";
> = 0.5;

// Эти UI элементы выключены, т.к. не влияют на расчет
//uniform float Era < ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.01; ui_label="Game Era (0-Old, 1-New)"; > = 0.0;
//uniform float Mood < ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.01; ui_label="Mood (0-Dark, 1-Bright)"; > = 0.0;

uniform float InputGamma <
    ui_type = "slider";
    ui_min = -2.4;
    ui_max = 2.4;
    ui_step = 0.01;
    ui_label = "Input Gamma";
    ui_tooltip = "Gamma correction for input image (default 1.0 preserves old logic)";
> = 1.0;

// Новые коэффициенты для расширенного расчёта локальной гаммы:
uniform float BrightnessCoef <
    ui_type = "slider";
    ui_min = 0.0;
    ui_max = 2.0;
    ui_step = 0.01;
    ui_label = "Brightness Coefficient";
    ui_tooltip = "BrightnessCoef (коэффициент яркости) отвечает за влияние яркости на адаптивную гамму. При увеличении этого параметра происходит смещение гаммы ближе к 1.0 (линейной), что делает яркие области менее контрастными и более светлыми, снижая эффект затемнения ярких пикселей. При уменьшении гаммы с яркостью эффект усиления контраста ярких участков выражен сильнее.";
> = 1.0;

uniform float ColorRangeCoef <
    ui_type = "slider";
    ui_min = 0.0;
    ui_max = 2.0;
    ui_step = 0.01;
    ui_label = "Color Range Coefficient";
    ui_tooltip = "ColorRangeCoef регулирует влияние цветового диапазона (разниц в RGB-каналах) на изменение гаммы. При увеличении этого параметра цвета с большим разбросом по каналам будут корректироваться гаммой ближе к 1.0, что делает насыщенные цвета более мягкими и менее контрастными. При низких значениях насыщенность и контраст цветов сохраняется.";
> = 1.0;

uniform float ContrastCoef <
    ui_type = "slider";
    ui_min = 0.0;
    ui_max = 2.0;
    ui_step = 0.01;
    ui_label = "Contrast Coefficient";
    ui_tooltip = "ContrastCoef влияет на гамму через контраст, измеряемый отклонением яркости от среднего значения (0.5). Увеличение этого коэффициента усиливает коррекцию гаммы в зависимости от контраста, что позволяет более эффективно сглаживать резкие переходы яркости и повышать детализацию в среднеярких участках. При низких значениях контрастный эффект меньше сглаживается.";
> = 1.0;

texture BackBufferTex : COLOR;
sampler BackBuffer { Texture = BackBufferTex; };

float3 rgb_to_hsv(float3 c) {
    float4 K = float4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
    float4 p = c.g < c.b ? float4(c.bg, K.wz) : float4(c.gb, K.xy);
    float4 q = c.r < p.x ? float4(p.xyw, c.r) : float4(c.r, p.yzx);

    float d = q.x - min(q.w, q.y);
    float e = 1.0e-10;
    return float3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

float3 hsv_to_rgb(float3 c) {
    float4 K = float4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
    float3 p = abs(frac(c.xxx + K.xyz) * 6.0 - K.www);
    return c.z * lerp(K.xxx, saturate(p - K.xxx), c.y);
}

// Расчёт гаммы с учетом нескольких коэффициентов
float adaptive_gamma(float3 color, float luma,
                     float brightness_coef, float color_range_coef, float contrast_coef)
{
    float gamma_base = 2.2;

    // Расчет диапазона цвета как разница max-min RGB в норме (0..1)
    float color_range = max(color.r, max(color.g, color.b)) - min(color.r, min(color.g, color.b));

    // Учет контрастности как отклонение luma от 0.5
    float contrast = abs(luma - 0.5) * 2.0;

    // Применяем коэффициенты с линейной интерполяцией
    float gamma_brightness = lerp(gamma_base, 1.0, brightness_coef);
    float gamma_color_range = lerp(gamma_brightness, 1.0, color_range_coef * color_range);
    float gamma_contrast = lerp(gamma_color_range, 1.0, contrast_coef * contrast);

    return lerp(gamma_base, gamma_contrast, saturate(luma));
}

float4 PS(float4 pos : SV_POSITION, float2 texcoord : TEXCOORD) : SV_TARGET
{
    float3 color = tex2D(BackBuffer, texcoord).rgb;

    float luma = dot(color, float3(0.2126, 0.7152, 0.0722));

    float per_pixel_gamma = adaptive_gamma(color, luma, BrightnessCoef, ColorRangeCoef, ContrastCoef);

    float3 color_gamma_corrected = pow(color, per_pixel_gamma);

    float adaptiveRadius = GlowRadius * pow(saturate(luma - LumaThreshold) * 4.0, BlurSharpness) * GlowIntensity;
    
    float3 blurSum = float3(0.0, 0.0, 0.0);
    float weightSum = 0.0;
    const float2 texelSize = ReShade::PixelSize;
    const int sampleCount = 64;
    
    for (int i = 0; i < sampleCount; i++) {
        float angle = 6.283185 * i / sampleCount;
        float2 offset = float2(cos(angle), sin(angle)) * adaptiveRadius;
        float2 samplePos = texcoord + offset * texelSize;
        float3 sampleColorRaw = tex2D(BackBuffer, samplePos).rgb;

        float sampleLuma = dot(sampleColorRaw, float3(0.2126, 0.7152, 0.0722));
        float sampleGamma = adaptive_gamma(sampleColorRaw, sampleLuma, BrightnessCoef, ColorRangeCoef, ContrastCoef);
        float3 sampleColor = pow(sampleColorRaw, sampleGamma);

        float distanceWeight = 1.0 - length(offset) / adaptiveRadius;
        float lumaWeight = pow(saturate(sampleLuma), 2.0);
        float totalWeight = distanceWeight * lumaWeight;

        blurSum += sampleColor * totalWeight;
        weightSum += totalWeight;
    }

    float3 blurred = weightSum > 0.001 ? blurSum / weightSum : color_gamma_corrected;

    float blendFactor = saturate(luma * 2.0) * GlowIntensity;
    float3 result = lerp(color_gamma_corrected, blurred * ((mymult * mymult) / 2), blendFactor);
    float contrastBoost = saturate((luma - 0.5) * GlowIntensity * 2.0);
    result = lerp(result, result * result * 1.2, contrastBoost);

    float outGamma = 1.0 / per_pixel_gamma;
    result = pow(result, outGamma);

    return float4(result, 1.0);
}

technique CRT_Dynamic_Glow
{
    pass
    {
        VertexShader = PostProcessVS;
        PixelShader = PS;
    }
}
