 #include "Reshade.fxh"
// Uniform-переменные

uniform float K <
    ui_label = "K";
    ui_type = "slider";
    ui_min = 0.0;
    ui_max = 200.0;
    ui_step = 0.01;
> = 200.0;

uniform float K2 <
    ui_label = "K2";
    ui_type = "slider";
    ui_min = 0.0;
    ui_max = 5.0;
    ui_step = 0.01;
> = 0.15;

uniform float K3 <
    ui_label = "K3";
    ui_type = "slider";
    ui_min = 0.0;
    ui_max = 50.0;
    ui_step = 0.01;
> = 8.0;

uniform float UIRadius <
    ui_label = "Radius";
    ui_type = "slider";
    ui_min = 1.0;
    ui_max = 50.0;
    ui_step = 1.0;
> = 8.0;

uniform float UIRedIntensity <
    ui_label = "Red Intensity";
    ui_type = "slider";
    ui_min = 0.0;
    ui_max = 1.0;
    ui_step = 0.01;
> = 1.0;

uniform float UIGreenIntensity <
    ui_label = "Green Intensity";
    ui_type = "slider";
    ui_min = 0.0;
    ui_max = 1.0;
    ui_step = 0.01;
> = 1.0;

uniform float UIBlueIntensity <
    ui_label = "Blue Intensity";
    ui_type = "slider";
    ui_min = 0.0;
    ui_max = 1.0;
    ui_step = 0.01;
> = 1.0;

// Текстура и семплер
//texture2D ColorTexture;
//sampler2D ColorSampler { Texture = ColorTexture; };

texture ColorTexture : COLOR;
sampler ColorSampler { Texture = ColorTexture; };

// Функция создания монохромных текстур
float3 createMonochromaticTextures(float2 uv)
{
    return float3(UIRedIntensity, UIGreenIntensity, UIBlueIntensity);
}

// Функция симуляции смещения массы
float simulateMassDisplacement(float2 uv, float channelEnergy, float2 originalCoord, float radius, float mass)
{
    float totalMass = 0.0;
    float samples = 1.0;
    
    // Получаем размер пикселя
    float2 pixelSize = float2(1.0 / BUFFER_WIDTH, 1.0 / BUFFER_HEIGHT);
    
    // Проходим по всем пикселям в радиусе
    for (float x = -radius; x <= radius; x++)
    {
        for (float y = -radius; y <= radius; y++)
        {
            float2 offset = float2(x, y) * pixelSize;
            float2 sampleCoord = originalCoord + offset;
            
            // Проверяем границы текстуры
            if (sampleCoord.x >= 0.0 && sampleCoord.x <= 1.0 && 
                sampleCoord.y >= 0.0 && sampleCoord.y <= 1.0)
            {
                // Вычисляем расстояние от центрального пикселя
                float distance = length(offset * float2(BUFFER_WIDTH, BUFFER_HEIGHT));
                
                if (distance <= radius)
                {
                    // Коэффициент затухания в зависимости от расстояния
                    float attenuation = (1.0 - (distance / radius))*K3;
                    
                    // Эффективная энергия, дошедшая до пикселя
                    float effectiveEnergy = (channelEnergy * attenuation)*K2;
                    
                    // Вычисляем смещенную массу
                    float displacedMass = mass * (1.0 - effectiveEnergy)*K;
                    
                    // Если это текущий пиксель, добавляем его вклад
                    if (all(sampleCoord == uv))
                    {
                        totalMass += displacedMass;
                    }
                    
                    samples += 1.0;
                }
            }
        }
    }
    
    // Усредняем результат
    if (samples > 0.0)
    {
        return totalMass / samples;
    }
    return totalMass;
}

// Основная функция шейдера
float4 PS_MassDisplacement(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    // Получаем исходный цвет
    float4 originalColor = tex2D(ColorSampler, uv);
    
    // Создаем монохромные текстуры
    float3 monoTextures = createMonochromaticTextures(uv);
    
    // Симулируем распространение для каждого канала
    float redMass = simulateMassDisplacement(uv, originalColor.r, uv, UIRadius, monoTextures.r);
    float greenMass = simulateMassDisplacement(uv, originalColor.g, uv, UIRadius, monoTextures.g);
    float blueMass = simulateMassDisplacement(uv, originalColor.b, uv, UIRadius, monoTextures.b);
    
    // Инвертируем интенсивность и нормализуем
    float finalRed = 1.0 - redMass;
    float finalGreen = 1.0 - greenMass;
    float finalBlue = 1.0 - blueMass;
    
    // Ограничиваем значения
    finalRed = clamp(finalRed, 0.0, 1.0);
    finalGreen = clamp(finalGreen, 0.0, 1.0);
    finalBlue = clamp(finalBlue, 0.0, 1.0);
    
    return float4(finalRed, finalGreen, finalBlue, 1.0);
}

// Техника
technique MassDisplacementTechnique
{
    pass Pass0
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_MassDisplacement;
    }
}