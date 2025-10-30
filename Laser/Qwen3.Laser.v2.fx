#include "reshade.fxh"

// === ОБЪЯВЛЕНИЕ 1x1 ТЕКСТУР ДЛЯ СЧЁТЧИКА КАДРОВ ===
texture2D FrameCounterBuffer { Width = 1; Height = 1; Format = R32F; };
sampler2D FrameCounterSampler { Texture = FrameCounterBuffer; };
texture2D TempCounterBuffer { Width = 1; Height = 1; Format = R32F; };
sampler2D TempCounterSampler { Texture = TempCounterBuffer; };

// === ПАРАМЕТРЫ ===
uniform float speed_per_frame = BUFFER_WIDTH;
uniform float decay = 0.5;
uniform float maxFrames = BUFFER_WIDTH * BUFFER_HEIGHT;
uniform float brightness = 1.5;
uniform float scanLine_per_frame = 1.0;
uniform float overlay_strength = 0.3; // Сила наложения эффекта

// Текстура входного изображения
texture2D MainTexture : COLOR;
sampler2D MainSampler { Texture = MainTexture; };

// === ОСНОВНОЙ ПИКСЕЛЬНЫЙ ШЕДЕР ===
float4 PS_Main(float4 pos : SV_Position,float2 TexCoord : TEXCOORD0) : SV_Target
{
    float2 resolution = float2(BUFFER_WIDTH, BUFFER_HEIGHT);
    float screenWidth = resolution.x;
    float screenHeight = resolution.y;

    // Читаем текущий счётчик кадров
    float frame_count = tex2D(FrameCounterSampler, float2(0.5, 0.5)).r;

    // Позиция луча в пикселях (циклическая, как в оригинале)
    float temp_x = frame_count * speed_per_frame;
    float x_current_px = temp_x - floor(temp_x / screenWidth) * screenWidth;
    float temp_y = frame_count * speed_per_frame * scanLine_per_frame;
    float y_current_px = temp_y - floor(temp_y / screenHeight) * screenHeight;

    // Текущие координаты пикселя в пикселях
    float2 pixel_px = TexCoord * resolution;

    // Рассчитываем разницу от пикселя до луча (в пикселях)
    float2 delta_px = pixel_px - float2(x_current_px, y_current_px);

    // Обработка цикличности (для корректного расчёта расстояния на краях экрана)
    if (delta_px.x > screenWidth * 0.5) delta_px.x -= screenWidth;
    if (delta_px.x < -screenWidth * 0.5) delta_px.x += screenWidth;
    if (delta_px.y > screenHeight * 0.5) delta_px.y -= screenHeight;
    if (delta_px.y < -screenHeight * 0.5) delta_px.y += screenHeight;

    // Вычисляем ЕВКЛИДОВО расстояние (в пикселях)
    float dist_px = length(delta_px);

    // "Время", прошедшее с момента прохождения луча (в кадрах)
    // Это основное исправление: frame_offset теперь зависит от расстояния
    float frame_offset = dist_px / speed_per_frame;

    // Затухание (экспоненциальное)
    float phos_brightness = exp(-decay * frame_offset);

    // Ограничение по времени жизни
    if (frame_offset > maxFrames) phos_brightness = 0.0;
    phos_brightness = max(0.0, phos_brightness);

    // Исходный цвет
    float4 original = tex2D(MainSampler, TexCoord);

    // Цветное свечение: используем оригинальный цвет пикселя
    float3 glow = original.rgb*phos_brightness * brightness;

    // Смешиваем: оригинальное изображение + аддитивный эффект с коэффициентом
    float3 final_rgb = original.rgb + glow * overlay_strength;

    return float4(final_rgb, original.a);
}

// === ШЕЙДЕРЫ ОБНОВЛЕНИЯ СЧЁТЧИКА (как в оригинале) ===
float4 PS_UpdateCounter(float4 pos : SV_Position, float2 texcoord : TEXCOORD0) : SV_Target
{
    float old_frame_count = tex2D(FrameCounterSampler, float2(0.5, 0.5)).r;
    float new_frame_count = old_frame_count + 1.0;
    return float4(new_frame_count, 0.0, 0.0, 1.0);
}

float4 PS_CopyTempToMain(float4 pos : SV_Position, float2 texcoord : TEXCOORD0) : SV_Target
{
    float new_frame_count = tex2D(TempCounterSampler, float2(0.5, 0.5)).r;
    return float4(new_frame_count, 0.0, 0.0, 1.0);
}

// === ТЕХНИКА ===
// Обновляем счётчик, копируем, затем применяем эффект
technique CRT_Light_Trail_Overlay_Corrected
{
    pass UpdateCounter
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_UpdateCounter;
        RenderTarget = TempCounterBuffer;
    }
    pass CopyTempToMain
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_CopyTempToMain;
        RenderTarget = FrameCounterBuffer;
    }
    pass MainEffect
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_Main;
    }
}