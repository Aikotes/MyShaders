// CRT_Dynamic_Glow.fx
// Reshade 6.1.1
#include "ReShade.fxh"
uniform float mymult=1.44;
/* uniform float GlowIntensity <
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
> = 0.5; */


uniform float Era < ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.01; ui_label="Game Era (0-Old, 1-New)"; > = 0.0;
uniform float Mood < ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.01; ui_label="Mood (0-Dark, 1-Bright)"; > = 0.0;

uniform float InputGamma <
    ui_type = "slider";
    ui_min = -2.4;
    ui_max = 2.4;
    ui_step = 0.01;
    ui_label = "Input Gamma";
    ui_tooltip = "Gamma correction for input image (default 1.0 preserves old logic)";
> = 1.0;


//float lerp(float a, float b, float t) { return a + (b - a) * t; }




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

float4 PS(float4 pos : SV_POSITION, float2 texcoord : TEXCOORD) : SV_TARGET
{

// Применяем обратную гамма-коррекцию к входному цвету
float3 color = pow(tex2D(BackBuffer, texcoord).rgb, InputGamma);

float GlowIntensity = lerp(lerp(0.60, 0.48, Mood), lerp(0.38, 0.27, Mood), Era);
float GlowRadius = lerp(lerp(22.0, 28.0, Mood), lerp(18.0, 36.0, Mood), Era);
float LumaThreshold = lerp(lerp(0.12, 0.06, Mood), lerp(0.18, 0.04, Mood), Era);
float BlurSharpness = lerp(lerp(1.2, 0.7, Mood), lerp(1.7, 0.5, Mood), Era);

    // Исходный цвет пикселя
   // float3 color = tex2D(BackBuffer, texcoord).rgb;
    
    // Рассчитываем яркость с учетом человеческого восприятия
    float luma = dot(color, float3(0.2126, 0.7152, 0.0722));
    
    // Адаптивный радиус размытия на основе яркости
    float adaptiveRadius = GlowRadius * pow(saturate(luma - LumaThreshold) * 4.0, BlurSharpness) * GlowIntensity;
    
    // Инициализация переменных для накопления
    float3 blurSum = float3(0.0, 0.0, 0.0);
    float weightSum = 0.0;
    
    // Оптимизированный цикл размытия с переменным радиусом
    const float2 texelSize = ReShade::PixelSize;
    const int sampleCount = 64;
    
    for (int i = 0; i < sampleCount; i++) {
        // Равномерное распределение сэмплов по кругу
        float angle = 6.283185 * i / sampleCount;
        float2 offset = float2(cos(angle), sin(angle)) * adaptiveRadius;
        
        // Координаты сэмпла
        float2 samplePos = texcoord + offset * texelSize;
       float3 sampleColor = pow(tex2D(BackBuffer, samplePos).rgb, InputGamma);
        //float3 sampleColor = tex2D(BackBuffer, samplePos).rgb;
        
        // Яркость сэмпла
        float sampleLuma = dot(sampleColor, float3(0.2126, 0.7152, 0.0722));
        
        // Вес сэмпла на основе расстояния и яркости
        float distanceWeight = 1.0 - length(offset) / adaptiveRadius;
        float lumaWeight = pow(saturate(sampleLuma), 2.0);
        float totalWeight = distanceWeight * lumaWeight;
        
        blurSum += sampleColor * totalWeight;
        weightSum += totalWeight;
		
		

    }
    
    // Нормализация
    float3 blurred = weightSum > 0.001 ? blurSum / weightSum : color;
    
    // Смешивание с оригиналом с сохранением детализации
    float blendFactor = saturate(luma * 2.0) * GlowIntensity;
    float3 result = lerp(color, blurred*((mymult*mymult)/2), blendFactor);
    
    //result=result*mymult;
    
    // Усиление контраста в ярких областях
    float contrastBoost = saturate((luma - 0.5) * GlowIntensity * 2.0);
    result = lerp(result, result * result * 1.2, contrastBoost);
    
   // result=result*mymult;
   
   result = pow(result, 1.0 / InputGamma);

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
