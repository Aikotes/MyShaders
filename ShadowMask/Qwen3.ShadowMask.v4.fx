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

// Параметр для двухуровневого размытия
uniform float inter_blur <
    ui_label = "Межпиксельное размытие (2-Level Graph PSF)";
    ui_tooltip = "Сила топологически корректного двухуровневого межпиксельного размытия, взвешенного по PSF фосфора";
    ui_type = "slider";
    ui_min = 0.0;
    ui_max = 2.0;
    ui_step = 0.01;
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
texture2D intraInfluenceTexture { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA16F; };
texture2D persistenceBuffer { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA16F; };
texture2D crtOutputTexture { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA16F; };

sampler2D sourceSampler { Texture = sourceTexture; };
sampler2D intraInfluenceSampler { Texture = intraInfluenceTexture; }; // <-- Используется для Level 2
sampler2D persistenceSampler { Texture = persistenceBuffer; };
sampler2D crtOutputSampler { Texture = crtOutputTexture; };

// --- Вспомогательная функция для вычисления гексагонального размытия ---
// Эта функция теперь может быть вызвана рекурсивно (хотя и не будет на самом деле рекурсивной).
// Вход: sampler, координаты, sigma для PSF.
// Возвращает: размытый цвет в заданной точке.

// === ВНУТРИПИКСЕЛЬНОЕ ВЛИЯНИЕ (из v1) ===
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

float3 computeHexBlur(sampler2D input_sampler, float2 texcoord, float2 texsize, float sigma_psf)
{
    float2 texel_size = float2(BUFFER_RCP_WIDTH, BUFFER_RCP_HEIGHT);
    float3 center = tex2D(input_sampler, texcoord).rgb;

    // --- Собираем 3x3 блок ---
    float3 block[9];
    block[0] = tex2D(input_sampler, texcoord + float2(-1, -1) * texel_size).rgb; // 0
    block[1] = tex2D(input_sampler, texcoord + float2( 0, -1) * texel_size).rgb; // 1
    block[2] = tex2D(input_sampler, texcoord + float2( 1, -1) * texel_size).rgb; // 2
    block[3] = tex2D(input_sampler, texcoord + float2(-1,  0) * texel_size).rgb; // 3
    block[4] = center; // 4
    block[5] = tex2D(input_sampler, texcoord + float2( 1,  0) * texel_size).rgb; // 5
    block[6] = tex2D(input_sampler, texcoord + float2(-1,  1) * texel_size).rgb; // 6
    block[7] = tex2D(input_sampler, texcoord + float2( 0,  1) * texel_size).rgb; // 7
    block[8] = tex2D(input_sampler, texcoord + float2( 1,  1) * texel_size).rgb; // 8

    // --- Гексагональные смещения ---
    float2 hex_offsets[6] = {
        float2(1.0, 0.0),   // Справа
        float2(-1.0, 0.0),  // Слева
        float2(0.5, 0.866), // Правый верх
        float2(-0.5, 0.866),// Левый верх
        float2(0.5, -0.866),// Правый низ
        float2(-0.5, -0.866) // Левый низ
    };

    // --- Интерполируем значения в гексагональных точках - РАЗВЁРНУТЫЙ ЦИКЛ ---
    float3 hex_values[6];
    // i = 0
    {
        float u = hex_offsets[0].x; float v = hex_offsets[0].y;
        float y_sq = v / (sqrt(3.0) / 2.0);
        float x_sq = u + 0.5 * (frac(y_sq * 0.5) > 0.5 ? 1 : 0);
        float2 sq_coord = float2(x_sq + 1.0, y_sq + 1.0);
        float2 f = frac(sq_coord); float2 i_coord = floor(sq_coord);
        int2 i0 = clamp(int2(i_coord.x, i_coord.y), int2(0, 0), int2(2, 2));
        int2 i1 = clamp(i0 + int2(1, 1), int2(0, 0), int2(2, 2));
        float3 I00 = block[i0.y * 3 + i0.x];
        float3 I10 = block[i0.y * 3 + i1.x];
        float3 I01 = block[i1.y * 3 + i0.x];
        float3 I11 = block[i1.y * 3 + i1.x];
        hex_values[0] = lerp(lerp(I00, I10, f.x), lerp(I01, I11, f.x), f.y);
    }
    // i = 1
    {
        float u = hex_offsets[1].x; float v = hex_offsets[1].y;
        float y_sq = v / (sqrt(3.0) / 2.0);
        float x_sq = u + 0.5 * (frac(y_sq * 0.5) > 0.5 ? 1 : 0);
        float2 sq_coord = float2(x_sq + 1.0, y_sq + 1.0);
        float2 f = frac(sq_coord); float2 i_coord = floor(sq_coord);
        int2 i0 = clamp(int2(i_coord.x, i_coord.y), int2(0, 0), int2(2, 2));
        int2 i1 = clamp(i0 + int2(1, 1), int2(0, 0), int2(2, 2));
        float3 I00 = block[i0.y * 3 + i0.x];
        float3 I10 = block[i0.y * 3 + i1.x];
        float3 I01 = block[i1.y * 3 + i0.x];
        float3 I11 = block[i1.y * 3 + i1.x];
        hex_values[1] = lerp(lerp(I00, I10, f.x), lerp(I01, I11, f.x), f.y);
    }
    // i = 2
    {
        float u = hex_offsets[2].x; float v = hex_offsets[2].y;
        float y_sq = v / (sqrt(3.0) / 2.0);
        float x_sq = u + 0.5 * (frac(y_sq * 0.5) > 0.5 ? 1 : 0);
        float2 sq_coord = float2(x_sq + 1.0, y_sq + 1.0);
        float2 f = frac(sq_coord); float2 i_coord = floor(sq_coord);
        int2 i0 = clamp(int2(i_coord.x, i_coord.y), int2(0, 0), int2(2, 2));
        int2 i1 = clamp(i0 + int2(1, 1), int2(0, 0), int2(2, 2));
        float3 I00 = block[i0.y * 3 + i0.x];
        float3 I10 = block[i0.y * 3 + i1.x];
        float3 I01 = block[i1.y * 3 + i0.x];
        float3 I11 = block[i1.y * 3 + i1.x];
        hex_values[2] = lerp(lerp(I00, I10, f.x), lerp(I01, I11, f.x), f.y);
    }
    // i = 3
    {
        float u = hex_offsets[3].x; float v = hex_offsets[3].y;
        float y_sq = v / (sqrt(3.0) / 2.0);
        float x_sq = u + 0.5 * (frac(y_sq * 0.5) > 0.5 ? 1 : 0);
        float2 sq_coord = float2(x_sq + 1.0, y_sq + 1.0);
        float2 f = frac(sq_coord); float2 i_coord = floor(sq_coord);
        int2 i0 = clamp(int2(i_coord.x, i_coord.y), int2(0, 0), int2(2, 2));
        int2 i1 = clamp(i0 + int2(1, 1), int2(0, 0), int2(2, 2));
        float3 I00 = block[i0.y * 3 + i0.x];
        float3 I10 = block[i0.y * 3 + i1.x];
        float3 I01 = block[i1.y * 3 + i0.x];
        float3 I11 = block[i1.y * 3 + i1.x];
        hex_values[3] = lerp(lerp(I00, I10, f.x), lerp(I01, I11, f.x), f.y);
    }
    // i = 4
    {
        float u = hex_offsets[4].x; float v = hex_offsets[4].y;
        float y_sq = v / (sqrt(3.0) / 2.0);
        float x_sq = u + 0.5 * (frac(y_sq * 0.5) > 0.5 ? 1 : 0);
        float2 sq_coord = float2(x_sq + 1.0, y_sq + 1.0);
        float2 f = frac(sq_coord); float2 i_coord = floor(sq_coord);
        int2 i0 = clamp(int2(i_coord.x, i_coord.y), int2(0, 0), int2(2, 2));
        int2 i1 = clamp(i0 + int2(1, 1), int2(0, 0), int2(2, 2));
        float3 I00 = block[i0.y * 3 + i0.x];
        float3 I10 = block[i0.y * 3 + i1.x];
        float3 I01 = block[i1.y * 3 + i0.x];
        float3 I11 = block[i1.y * 3 + i1.x];
        hex_values[4] = lerp(lerp(I00, I10, f.x), lerp(I01, I11, f.x), f.y);
    }
    // i = 5
    {
        float u = hex_offsets[5].x; float v = hex_offsets[5].y;
        float y_sq = v / (sqrt(3.0) / 2.0);
        float x_sq = u + 0.5 * (frac(y_sq * 0.5) > 0.5 ? 1 : 0);
        float2 sq_coord = float2(x_sq + 1.0, y_sq + 1.0);
        float2 f = frac(sq_coord); float2 i_coord = floor(sq_coord);
        int2 i0 = clamp(int2(i_coord.x, i_coord.y), int2(0, 0), int2(2, 2));
        int2 i1 = clamp(i0 + int2(1, 1), int2(0, 0), int2(2, 2));
        float3 I00 = block[i0.y * 3 + i0.x];
        float3 I10 = block[i0.y * 3 + i1.x];
        float3 I01 = block[i1.y * 3 + i0.x];
        float3 I11 = block[i1.y * 3 + i1.x];
        hex_values[5] = lerp(lerp(I00, I10, f.x), lerp(I01, I11, f.x), f.y);
    }

    // --- PSF-взвешенное смешивание ---
    float w_neighbor_psf = exp(-1.0 / (2.0 * sigma_psf * sigma_psf)); // d^2 = 1
    float3 neighbor_sum = hex_values[0] + hex_values[1] + hex_values[2] + hex_values[3] + hex_values[4] + hex_values[5];
    float3 total_neighbor_contribution = w_neighbor_psf * neighbor_sum;
    float w_center = 1.0;
    float total_weight = w_center + 6 * w_neighbor_psf;
    float3 normalized_blur = (w_center * center + total_neighbor_contribution) / total_weight;
    return normalized_blur; // Возвращаем нормализованный результат размытия
}

// === ДВУХУРОВНЕВОЕ РАЗМЫТИЕ (Обновлённое) ===
float3 graphBasedBlur2Level(float2 texcoord, float2 texsize)
{
    float sigma_psf = max(inter_blur, 0.001);

    // --- Уровень 1: Вычисляем размытие для 6 соседних гексагональных точек ---
    // Используем intraInfluenceSampler как "сырой" вход для Level 1
    float2 texel_size = float2(BUFFER_RCP_WIDTH, BUFFER_RCP_HEIGHT);

    float2 hex_offsets[6] = {
        float2(1.0, 0.0),   // Справа
        float2(-1.0, 0.0),  // Слева
        float2(0.5, 0.866), // Правый верх
        float2(-0.5, 0.866),// Левый верх
        float2(0.5, -0.866),// Правый низ
        float2(-0.5, -0.866) // Левый низ
    };

    float3 blurred_neighbors[6];
    for (int i = 0; i < 6; i++) {
         float u = hex_offsets[i].x;
         float v = hex_offsets[i].y;
         float y_sq = v / (sqrt(3.0) / 2.0);
         float x_sq = u + 0.5 * (frac(y_sq * 0.5) > 0.5 ? 1 : 0);
         float2 local_texcoord = texcoord + float2(x_sq * texel_size.x, y_sq * texel_size.y);
         blurred_neighbors[i] = computeHexBlur(intraInfluenceSampler, local_texcoord, texsize, sigma_psf);
    }

    // --- Уровень 2: Используем размытые значения соседей для размытия центральной точки ---
    // Центральная точка из intraInfluenceTexture
    float3 center = tex2D(intraInfluenceSampler, texcoord).rgb;

    // Веса для Level 2. Можно использовать тот же sigma_psf, или другой.
    // PSF-подобный вес для размытых соседей
    float w_blurred_neighbor_psf = exp(-1.0 / (2.0 * sigma_psf * sigma_psf)); // d^2 = 1
    float w_center_2 = 1.0; // Вес центральной точки на Level 2

    // Суммируем вклады размытых соседей
    float3 total_blurred_neighbor_contribution = w_blurred_neighbor_psf * (
        blurred_neighbors[0] + blurred_neighbors[1] + blurred_neighbors[2] +
        blurred_neighbors[3] + blurred_neighbors[4] + blurred_neighbors[5]
    );

    // Нормализуем
    float total_weight_2 = w_center_2 + 6 * w_blurred_neighbor_psf;
    float3 normalized_blur_2 = (w_center_2 * center + total_blurred_neighbor_contribution) / total_weight_2;

    // Используем inter_blur как степень влияния финального результата Level 2
    float3 final_color = lerp(center, normalized_blur_2, saturate(inter_blur));

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

// === ПРОХОД 2: Двухуровневое физически-взвешенное межпиксельное размытие → crtOutputTexture ===
float4 Pass2_PS(float4 pos : SV_Position, float2 texcoord : TEXCOORD0) : SV_Target
{
    float3 blurred = graphBasedBlur2Level(texcoord, float2(BUFFER_WIDTH, BUFFER_HEIGHT));
    return float4(blurred, 1.0);
}

// === ПРОХОД 3: Обновление буфера послесвечения ===
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
    float3 final = pow(saturate(persistent), 1.0 / crt_gamma);
    return float4(final, 1.0);
}



// === ТЕХНИКА ===
technique CRT_Effect_With_2Level_Graph_Blur
{
    pass IntraPixelInfluence
    {
        VertexShader = PostProcessVS;
        PixelShader = Pass1_PS;
        RenderTarget = intraInfluenceTexture;
    }
    pass InterPixelGraphBlur2Level // Переименован проход
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