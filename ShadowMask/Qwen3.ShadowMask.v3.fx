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
> = 0.9;

uniform float intra_blur <
    ui_label = "Внутрипиксельное размытие";
    ui_tooltip = "Сила влияния цветов внутри пикселя (каналы смешиваются)";
    ui_type = "slider";
    ui_min = 0.0;
    ui_max = 2.0;
    ui_step = 0.01;
> = 0.27;

// Параметр для физически-взвешенного размытия по графу
uniform float inter_blur <
    ui_label = "Межпиксельное размытие (Graph PSF)";
    ui_tooltip = "Сила топологически корректного межпиксельного размытия, взвешенного по PSF фосфора";
    ui_type = "slider";
    ui_min = 0.0; // Нет размытия
    ui_max = 2.0; // Максимальное размытие (можно подобрать)
    ui_step = 0.01;
> = 0.626; // Или подберите значение по вкусу

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
// Промежуточный буфер после внутрипиксельного влияния и ослабления маской
texture2D intraInfluenceTexture { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA16F; };
// Буфер для хранения предыдущего кадра (для послесвечения)
texture2D persistenceBuffer { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA16F; };
// Финальный CRT-выход до гаммы и persistence-смешивания
texture2D crtOutputTexture { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA16F; };

sampler2D sourceSampler { Texture = sourceTexture; };
sampler2D intraInfluenceSampler { Texture = intraInfluenceTexture; };
sampler2D persistenceSampler { Texture = persistenceBuffer; };
sampler2D crtOutputSampler { Texture = crtOutputTexture; };

// === ВНУТРИПИКСЕЛЬНОЕ ВЛИЯНИЕ (Оригинал из v1) ===
float3 calculateIntraPixelInfluence(float2 texcoord, float2 texsize, float3 baseColor)
{
    float2 pixelSize = 1.0 / texsize;
    float2 r_uv = float2(0.0, 0.0);
    float2 g_uv = float2(mask_step * pixelSize.x, 0.0);
    float2 b_uv = float2(0.5 * mask_step * pixelSize.x, 0.866 * mask_step * pixelSize.y);

    float r = tex2D(sourceSampler, texcoord + r_uv).r;
    float g = tex2D(sourceSampler, texcoord + g_uv).g;
    float b = tex2D(sourceSampler, texcoord + b_uv).b;

    float d_rg = mask_step;
    float d_rb = mask_step;
    float d_gb = mask_step;

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

// === ФИЗИЧЕСКИ-ВЗВЕШЕННОЕ МЕЖПИКСЕЛЬНОЕ РАЗМЫТИЕ (Обновлённое из v2) ===
float3 graphBasedBlur(float2 texcoord, float2 texsize)
{
    float2 texel_size = float2(BUFFER_RCP_WIDTH, BUFFER_RCP_HEIGHT); // 1/width, 1/height
    float3 center = tex2D(intraInfluenceSampler, texcoord).rgb;

    // Собираем 3x3 блок (в пиксельных смещениях) - РАЗВЁРНУТЫЙ ЦИКЛ
    float3 block_00 = tex2D(intraInfluenceSampler, texcoord + float2(-1, -1) * texel_size).rgb;
    float3 block_01 = tex2D(intraInfluenceSampler, texcoord + float2( 0, -1) * texel_size).rgb;
    float3 block_02 = tex2D(intraInfluenceSampler, texcoord + float2( 1, -1) * texel_size).rgb;
    float3 block_10 = tex2D(intraInfluenceSampler, texcoord + float2(-1,  0) * texel_size).rgb;
    float3 block_11 = center; // [ 0,  0] - центр
    float3 block_12 = tex2D(intraInfluenceSampler, texcoord + float2( 1,  0) * texel_size).rgb;
    float3 block_20 = tex2D(intraInfluenceSampler, texcoord + float2(-1,  1) * texel_size).rgb;
    float3 block_21 = tex2D(intraInfluenceSampler, texcoord + float2( 0,  1) * texel_size).rgb;
    float3 block_22 = tex2D(intraInfluenceSampler, texcoord + float2( 1,  1) * texel_size).rgb;

    float3 block[9] = {
        block_00, block_01, block_02,
        block_10, block_11, block_12,
        block_20, block_21, block_22
    };

    // Гексагональные смещения (u, v) из v2
    float2 hex_offsets[6] = {
        float2(1.0, 0.0),   // Справа
        float2(-1.0, 0.0),  // Слева
        float2(0.5, 0.866), // Правый верх
        float2(-0.5, 0.866),// Левый верх
        float2(0.5, -0.866),// Правый низ
        float2(-0.5, -0.866) // Левый низ
    };

    // --- Интерполируем значения в гексагональных точках - РАЗВЁРНУТЫЙ ЦИКЛ ---
    float3 hex_val_0, hex_val_1, hex_val_2, hex_val_3, hex_val_4, hex_val_5;

    // --- i = 0 ---
    {
        float u = hex_offsets[0].x; // 1.0
        float v = hex_offsets[0].y; // 0.0
        float y_sq = v / (sqrt(3.0) / 2.0);
        float x_sq = u + 0.5 * (frac(y_sq * 0.5) > 0.5 ? 1 : 0);
        float2 sq_coord = float2(x_sq + 1.0, y_sq + 1.0);
        float2 f = frac(sq_coord);
        float2 i_coord = floor(sq_coord);
        int2 i0 = clamp(int2(i_coord.x, i_coord.y), int2(0, 0), int2(2, 2));
        int2 i1 = clamp(i0 + int2(1, 1), int2(0, 0), int2(2, 2));
        float3 I00 = block[i0.y * 3 + i0.x];
        float3 I10 = block[i0.y * 3 + i1.x];
        float3 I01 = block[i1.y * 3 + i0.x];
        float3 I11 = block[i1.y * 3 + i1.x];
        hex_val_0 = lerp(lerp(I00, I10, f.x), lerp(I01, I11, f.x), f.y);
    }
    // --- i = 1 ---
    {
        float u = hex_offsets[1].x; // -1.0
        float v = hex_offsets[1].y; // 0.0
        float y_sq = v / (sqrt(3.0) / 2.0);
        float x_sq = u + 0.5 * (frac(y_sq * 0.5) > 0.5 ? 1 : 0);
        float2 sq_coord = float2(x_sq + 1.0, y_sq + 1.0);
        float2 f = frac(sq_coord);
        float2 i_coord = floor(sq_coord);
        int2 i0 = clamp(int2(i_coord.x, i_coord.y), int2(0, 0), int2(2, 2));
        int2 i1 = clamp(i0 + int2(1, 1), int2(0, 0), int2(2, 2));
        float3 I00 = block[i0.y * 3 + i0.x];
        float3 I10 = block[i0.y * 3 + i1.x];
        float3 I01 = block[i1.y * 3 + i0.x];
        float3 I11 = block[i1.y * 3 + i1.x];
        hex_val_1 = lerp(lerp(I00, I10, f.x), lerp(I01, I11, f.x), f.y);
    }
    // --- i = 2 ---
    {
        float u = hex_offsets[2].x; // 0.5
        float v = hex_offsets[2].y; // 0.866
        float y_sq = v / (sqrt(3.0) / 2.0);
        float x_sq = u + 0.5 * (frac(y_sq * 0.5) > 0.5 ? 1 : 0);
        float2 sq_coord = float2(x_sq + 1.0, y_sq + 1.0);
        float2 f = frac(sq_coord);
        float2 i_coord = floor(sq_coord);
        int2 i0 = clamp(int2(i_coord.x, i_coord.y), int2(0, 0), int2(2, 2));
        int2 i1 = clamp(i0 + int2(1, 1), int2(0, 0), int2(2, 2));
        float3 I00 = block[i0.y * 3 + i0.x];
        float3 I10 = block[i0.y * 3 + i1.x];
        float3 I01 = block[i1.y * 3 + i0.x];
        float3 I11 = block[i1.y * 3 + i1.x];
        hex_val_2 = lerp(lerp(I00, I10, f.x), lerp(I01, I11, f.x), f.y);
    }
    // --- i = 3 ---
    {
        float u = hex_offsets[3].x; // -0.5
        float v = hex_offsets[3].y; // 0.866
        float y_sq = v / (sqrt(3.0) / 2.0);
        float x_sq = u + 0.5 * (frac(y_sq * 0.5) > 0.5 ? 1 : 0);
        float2 sq_coord = float2(x_sq + 1.0, y_sq + 1.0);
        float2 f = frac(sq_coord);
        float2 i_coord = floor(sq_coord);
        int2 i0 = clamp(int2(i_coord.x, i_coord.y), int2(0, 0), int2(2, 2));
        int2 i1 = clamp(i0 + int2(1, 1), int2(0, 0), int2(2, 2));
        float3 I00 = block[i0.y * 3 + i0.x];
        float3 I10 = block[i0.y * 3 + i1.x];
        float3 I01 = block[i1.y * 3 + i0.x];
        float3 I11 = block[i1.y * 3 + i1.x];
        hex_val_3 = lerp(lerp(I00, I10, f.x), lerp(I01, I11, f.x), f.y);
    }
    // --- i = 4 ---
    {
        float u = hex_offsets[4].x; // 0.5
        float v = hex_offsets[4].y; // -0.866
        float y_sq = v / (sqrt(3.0) / 2.0);
        float x_sq = u + 0.5 * (frac(y_sq * 0.5) > 0.5 ? 1 : 0);
        float2 sq_coord = float2(x_sq + 1.0, y_sq + 1.0);
        float2 f = frac(sq_coord);
        float2 i_coord = floor(sq_coord);
        int2 i0 = clamp(int2(i_coord.x, i_coord.y), int2(0, 0), int2(2, 2));
        int2 i1 = clamp(i0 + int2(1, 1), int2(0, 0), int2(2, 2));
        float3 I00 = block[i0.y * 3 + i0.x];
        float3 I10 = block[i0.y * 3 + i1.x];
        float3 I01 = block[i1.y * 3 + i0.x];
        float3 I11 = block[i1.y * 3 + i1.x];
        hex_val_4 = lerp(lerp(I00, I10, f.x), lerp(I01, I11, f.x), f.y);
    }
    // --- i = 5 ---
    {
        float u = hex_offsets[5].x; // -0.5
        float v = hex_offsets[5].y; // -0.866
        float y_sq = v / (sqrt(3.0) / 2.0);
        float x_sq = u + 0.5 * (frac(y_sq * 0.5) > 0.5 ? 1 : 0);
        float2 sq_coord = float2(x_sq + 1.0, y_sq + 1.0);
        float2 f = frac(sq_coord);
        float2 i_coord = floor(sq_coord);
        int2 i0 = clamp(int2(i_coord.x, i_coord.y), int2(0, 0), int2(2, 2));
        int2 i1 = clamp(i0 + int2(1, 1), int2(0, 0), int2(2, 2));
        float3 I00 = block[i0.y * 3 + i0.x];
        float3 I10 = block[i0.y * 3 + i1.x];
        float3 I01 = block[i1.y * 3 + i0.x];
        float3 I11 = block[i1.y * 3 + i1.x];
        hex_val_5 = lerp(lerp(I00, I10, f.x), lerp(I01, I11, f.x), f.y);
    }

    float3 hex_values[6] = { hex_val_0, hex_val_1, hex_val_2, hex_val_3, hex_val_4, hex_val_5 };

    // --- ФИЗИЧЕСКИ-ВЗВЕШЕННОЕ СМЕШИВАНИЕ ---
    // Вместо фиксированных весов, вычисляем веса на основе расстояния.
    // В гексагональной решётке все 6 соседей находятся на одинаковом топологическом расстоянии (1 шаг).
    // Однако, физическое расстояние в UV может отличаться из-за аспекта пикселя.
    // Для упрощения, будем считать, что физическое расстояние пропорционально топологическому.
    // Используем гауссову PSF: w = exp(-(d^2) / (2 * sigma^2))
    // inter_blur будет управлять "широкостью" PSF (sigma).
    float sigma_psf = max(inter_blur, 0.001); // Избегаем деления на 0
    float dist_squared = 1.0; // Топологическое расстояние в квадрате для всех соседей

    float w_neighbor_psf = exp(-(dist_squared) / (2.0 * sigma_psf * sigma_psf));
    // Суммируем вклады всех соседей
    float3 neighbor_sum = hex_values[0] + hex_values[1] + hex_values[2] + hex_values[3] + hex_values[4] + hex_values[5];
    float3 total_neighbor_contribution = w_neighbor_psf * neighbor_sum;

    // Вклад центрального пикселя
    // Нормализуем, чтобы сумма весов не превышала 1, если не нужно усиление.
    // Общая сила размытия: w_center + 6 * w_neighbor_psf
    // Мы хотим, чтобы w_center был "остатком" после вклада соседей, но неотрицательным.
    // Или, как в предыдущем варианте, использовать inter_blur как общий коэффициент.
    // Попробуем: w_total = w_center_fixed + w_neighbors_scaled
    // w_center_fixed = 1.0 - clamp(6 * w_neighbor_psf, 0, 1) - если сумма соседей > 1, центр обнуляется.
    // Или: w_center = exp(0) = 1.0, w_neighbors = w_neighbor_psf, final_color = normalize( w_center * center + total_neighbor_contribution )
    // Или: final_color = lerp(center, (w_center * center + total_neighbor_contribution) / (w_center + 6 * w_neighbor_psf), inter_blur)
    // Попробуем простой подход: lerp между центром и нормализованным вкладом соседей.
    // Вклад центра: w_center = 1.0 (или можно сделать зависимым от inter_blur)
    float w_center = 1.0; // Держим центральный вклад постоянным
    float total_weight = w_center + 6 * w_neighbor_psf; // Общий вес
    float3 weighted_sum = w_center * center + total_neighbor_contribution;
    float3 normalized_blur = weighted_sum / total_weight; // Нормализованный результат размытия

    // Используем inter_blur как степень влияния размытого результата на финальный цвет
    // Это позволяет плавно регулировать силу размытия.
    float3 final_color = lerp(center, normalized_blur, saturate(inter_blur)); // lerp(исходный, размытый, степень_размытия)

    return saturate(final_color);
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

// === ПРОХОД 2: Физически-взвешенное межпиксельное размытие (Graph Blur PSF) → crtOutputTexture ===
float4 Pass2_PS(float4 pos : SV_Position, float2 texcoord : TEXCOORD0) : SV_Target
{
    float3 blurred = graphBasedBlur(texcoord, float2(BUFFER_WIDTH, BUFFER_HEIGHT));
    return float4(blurred, 1.0);
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
    float3 persistent = lerp(current, previous, persistence);
    // Применяем CRT-гамму только здесь
    float3 final = pow(saturate(persistent), 1.0 / crt_gamma);
    return float4(final, 1.0);
}

// === ТЕХНИКА ===
technique CRT_Effect_With_Physically_Weighted_Graph_Blur
{
    pass IntraPixelInfluence
    {
        VertexShader = PostProcessVS;
        PixelShader = Pass1_PS;
        RenderTarget = intraInfluenceTexture;
    }
    pass InterPixelGraphBlurPSF // Переименован проход
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
    }
}