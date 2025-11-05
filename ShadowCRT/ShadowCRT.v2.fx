#include "reshade.fxh"

// === ТЕКСТУРЫ И СЭМПЛЕРЫ ===
texture2D sourceTexture : COLOR;
texture2D AccumA { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA16F; };
texture2D AccumB { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA16F; };
sampler2D AccumASampler { Texture = AccumA; };
sampler2D AccumBSampler { Texture = AccumB; };
sampler2D sourceSampler { Texture = sourceTexture; };

// === ПАРАМЕТРЫ ТЕНЕВОЙ МАСКИ И ПОСЛЕСВЕЧЕНИЯ ===
uniform float pre_boost <
    ui_label = "Предусиление яркости";
    ui_tooltip = "Усиление яркости до ослабления маской";
    ui_type = "slider";
    ui_min = 1.0;
    ui_max = 3.0;
    ui_step = 0.1;
> = 2.2;

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
> = 0.32;

uniform float inter_blur <
    ui_label = "Межпиксельное размытие (2-Level Graph PSF)";
    ui_tooltip = "Сила топологически корректного двухуровневого межпиксельного размытия, взвешенного по PSF фосфора";
    ui_type = "slider";
    ui_min = 0.0;
    ui_max = 2.0;
    ui_step = 0.01;
> = 0.23;

uniform float mask_brightness_loss <
    ui_label = "Потери в маске";
    ui_tooltip = "Коэффициент потерь яркости в теневой маске (применяется ко всему цвету)";
    ui_type = "slider";
    ui_min = 0.5;
    ui_max = 0.8;
    ui_step = 0.01;
> = 0.65;

// --- НОВЫЕ ПАРАМЕТРЫ ДЛЯ СКАЙЛАЙНОВ ---
uniform int skyline_width <
    ui_label = "Ширина скайлайна (в строках)";
    ui_tooltip = "Количество строк подряд, которые будут затемнены (0 отключает скайлайны)";
    ui_type = "slider";
    ui_min = 0; // 0 отключает функцию
    ui_max = 10; // Установите максимум по желанию
    ui_step = 1;
> = 1;

uniform float skyline_block_coeff <
    ui_label = "Коэффициент блокировки скайлайна";
    ui_tooltip = "Коэффициент, на который умножается яркость строк, перекрытых маской (0 = полное обнуление, 1 = без изменений)";
    ui_type = "slider";
    ui_min = 0.0;
    ui_max = 1.0;
    ui_step = 0.01;
> = 0.0; // По умолчанию 0 - полное обнуление
// --- КОНЕЦ НОВЫХ ПАРАМЕТРОВ ---

uniform float crt_gamma <
    ui_label = "Гамма CRT";
    ui_tooltip = "Типичная гамма CRT-монитора (2.2–2.5)";
    ui_type = "slider";
    ui_min = 0.8;
    ui_max = 2.8;
    ui_step = 0.01;
> = 0.9;

// Параметры послесвечения (из Persistence.txt)
uniform float FPS < ui_type = "slider"; ui_min = 1.0; ui_max = 120.0; ui_step = 1.0; > = 40.0;
uniform float PersistenceR < ui_type = "drag"; ui_min = 0.01; ui_max = 1.0; ui_step = 0.01; > = 0.01;
uniform float PersistenceG < ui_type = "drag"; ui_min = 0.01; ui_max = 1.0; ui_step = 0.01; > = 0.01;
uniform float PersistenceB < ui_type = "drag"; ui_min = 0.01; ui_max = 1.0; ui_step = 0.01; > = 0.01;
uniform float InputGain     < ui_type = "drag"; ui_min = 0.0; ui_max = 2.0; ui_step = 0.01; > = 1.0;
uniform float OutputGain    < ui_type = "drag"; ui_min = 0.0; ui_max = 5.0; ui_step = 0.01; > = 1.12;
uniform float ResetThreshold< ui_type = "drag"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.01; > = 1.0;

uniform float near_radius < ui_min = 1; ui_max = 15; ui_step = 0.5; > = 5.0;
uniform float far_radius  < ui_min = 5; ui_max = 60; ui_step = 1.0; > = 25.0;

// === ПАРАМЕТРЫ ОПТИЧЕСКОГО СВЕЧЕНИЯ (PSF-based) ===
uniform float glow_threshold <
    ui_label = "Glow Threshold";
    ui_tooltip = "Линейная яркость, выше которой включается свечение";
    ui_type = "drag"; ui_min = 0.0; ui_max = 2.0; ui_step = 0.01;
> = 0.8;

uniform float glow_strength <
    ui_label = "Glow Strength";
    ui_tooltip = "Интенсивность свечения (аддитивно, не влияет на накопление)";
    ui_type = "drag"; ui_min = 0.0; ui_max = 2.0; ui_step = 0.01;
> = 0.3;

uniform float glow_radius <
    ui_label = "Glow Radius (PSF sigma)";
    ui_tooltip = "Радиус рассеяния свечения (в единицах PSF)";
    ui_type = "slider"; ui_min = 0.1; ui_max = 3.0; ui_step = 0.05;
> = 1.2;

// === ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ (из v8) ===
float3 computeHexBlur(sampler2D input_sampler, float2 texcoord, float2 texsize, float sigma_psf)
{
    float2 texel_size = float2(BUFFER_RCP_WIDTH, BUFFER_RCP_HEIGHT);
    float3 center = tex2D(input_sampler, texcoord).rgb;
    float3 block[9];
    block[0] = tex2D(input_sampler, texcoord + float2(-1, -1) * texel_size).rgb;
    block[1] = tex2D(input_sampler, texcoord + float2( 0, -1) * texel_size).rgb;
    block[2] = tex2D(input_sampler, texcoord + float2( 1, -1) * texel_size).rgb;
    block[3] = tex2D(input_sampler, texcoord + float2(-1,  0) * texel_size).rgb;
    block[4] = center;
    block[5] = tex2D(input_sampler, texcoord + float2( 1,  0) * texel_size).rgb;
    block[6] = tex2D(input_sampler, texcoord + float2(-1,  1) * texel_size).rgb;
    block[7] = tex2D(input_sampler, texcoord + float2( 0,  1) * texel_size).rgb;
    block[8] = tex2D(input_sampler, texcoord + float2( 1,  1) * texel_size).rgb;

    float2 hex_offsets[6] = {
        float2(1.0, 0.0),
        float2(-1.0, 0.0),
        float2(0.5, 0.866),
        float2(-0.5, 0.866),
        float2(0.5, -0.866),
        float2(-0.5, -0.866)
    };

    float3 hex_values[6];
    for (int i = 0; i < 6; i++)
    {
        float u = hex_offsets[i].x;
        float v = hex_offsets[i].y;
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
        hex_values[i] = lerp(lerp(I00, I10, f.x), lerp(I01, I11, f.x), f.y);
    }

    float w_neighbor_psf = exp(-1.0 / (2.0 * sigma_psf * sigma_psf));
    float3 neighbor_sum = hex_values[0] + hex_values[1] + hex_values[2] + hex_values[3] + hex_values[4] + hex_values[5];
    float3 total_neighbor_contribution = w_neighbor_psf * neighbor_sum;
    float w_center = 1.0;
    float total_weight = w_center + 6 * w_neighbor_psf;
    return (w_center * center + total_neighbor_contribution) / total_weight;
}

float3 graphBasedBlur2Level(sampler2D input_sampler, float2 texcoord, float2 texsize, float sigma_psf)
{
    float2 texel_size = float2(BUFFER_RCP_WIDTH, BUFFER_RCP_HEIGHT);
    float2 hex_offsets[6] = {
        float2(1.0, 0.0),
        float2(-1.0, 0.0),
        float2(0.5, 0.866),
        float2(-0.5, 0.866),
        float2(0.5, -0.866),
        float2(-0.5, -0.866)
    };

    float3 blurred_neighbors[6];
    for (int i = 0; i < 6; i++) {
        float u = hex_offsets[i].x;
        float v = hex_offsets[i].y;
        float y_sq = v / (sqrt(3.0) / 2.0);
        float x_sq = u + 0.5 * (frac(y_sq * 0.5) > 0.5 ? 1 : 0);
        float2 local_texcoord = texcoord + float2(x_sq * texel_size.x, y_sq * texel_size.y);
        blurred_neighbors[i] = computeHexBlur(input_sampler, local_texcoord, texsize, sigma_psf);
    }

    float3 center = tex2D(input_sampler, texcoord).rgb;
    float w_blurred_neighbor_psf = exp(-1.0 / (2.0 * sigma_psf * sigma_psf));
    float w_center_2 = 1.0;
    float3 total_blurred_neighbor_contribution = w_blurred_neighbor_psf * (
        blurred_neighbors[0] + blurred_neighbors[1] + blurred_neighbors[2] +
        blurred_neighbors[3] + blurred_neighbors[4] + blurred_neighbors[5]
    );
    float total_weight_2 = w_center_2 + 6 * w_blurred_neighbor_psf;
    float3 normalized_blur_2 = (w_center_2 * center + total_blurred_neighbor_contribution) / total_weight_2;
    return saturate(normalized_blur_2);
}

// === ВНУТРИПИКСЕЛЬНОЕ ВЛИЯНИЕ — ИСПОЛЬЗУЕТ ТОЛЬКО ИСХОДНОЕ ИЗОБРАЖЕНИЕ ===
float3 calculateIntraPixelInfluenceFromSource(float2 texcoord, float2 texsize, sampler2D input_sampler)
{
    float2 pixelSize = 1.0 / texsize;
    float2 r_uv = float2(0.0, 0.0);
    float2 g_uv = float2(mask_step * pixelSize.x, 0.0);
    float2 b_uv = float2(0.5 * mask_step * pixelSize.x, 0.866 * mask_step * pixelSize.y);

    float r = tex2D(input_sampler, texcoord + r_uv).r;
    float g = tex2D(input_sampler, texcoord + g_uv).g;
    float b = tex2D(input_sampler, texcoord + b_uv).b;

    float sigma = max(intra_blur, 0.001);
    float w = exp(-(mask_step * mask_step) / (2.0 * sigma * sigma));

    float3 result;
    result.r = r + g * w + b * w;
    result.g = g + r * w + b * w;
    result.b = b + r * w + g * w;
    return saturate(result);
}

// === ПРОХОД 1: ОБНОВЛЕНИЕ НАКОПЛЕНИЯ + INTRA_BLUR НА ЭТАПЕ ВОЗБУЖДЕНИЯ ===
float4 Pass1_UpdatePersistence(float4 vpos : SV_Position, float2 texcoord : TexCoord) : SV_Target
{
    float2 texsize = float2(BUFFER_WIDTH, BUFFER_HEIGHT);
    float3 current_srgb = tex2D(sourceSampler, texcoord).rgb;
    float3 current_linear = pow(current_srgb, 2.2);

    // 🔥 ФОСФОРНОЕ ВЗАИМОДЕЙСТВИЕ В ТРИАДЕ — ДО НАКОПЛЕНИЯ
    float3 intra_linear = calculateIntraPixelInfluenceFromSource(texcoord, texsize, sourceSampler);

    // НАКОПЛЕНИЕ
    float3 history_linear = tex2D(AccumASampler, texcoord).rgb;
    float dt = 1.0 / FPS;
    float3 tau = float3(PersistenceR, PersistenceG, PersistenceB);
    float3 alphas = exp(-dt / max(tau, 0.001));
    float3 decayed = history_linear * alphas;

    float avg_brightness = dot(intra_linear, float3(0.2126, 0.7152, 0.0722));
    float3 new_history = (avg_brightness > ResetThreshold)
        ? intra_linear * InputGain
        : decayed + intra_linear * InputGain;

    new_history = min(new_history, 10.0);
    return float4(new_history, avg_brightness);
}

float4 Pass2_CopyPersistence(float4 vpos : SV_Position, float2 texcoord : TexCoord) : SV_Target
{
    return tex2D(AccumBSampler, texcoord);
}

// === ПРОХОД 3: ТЕНЕВАЯ МАСКА (ТОЛЬКО ПОТЕРИ + BOOST) ===
// === ПРОХОД 3: ТЕНЕВАЯ МАСКА (ПОТЕРИ + СКАЙЛАЙНЫ) ===

// === ПРОХОД 3: ТЕНЕВАЯ МАСКА (ПОТЕРИ + СКАЙЛАЙНЫ) ===

float4 Pass3_ApplyShadowMask(float4 pos : SV_Position, float2 texcoord : TEXCOORD0) : SV_Target
{
    float3 baseColor_linear = tex2D(AccumASampler, texcoord).rgb;
    float3 modifiedColor_linear = baseColor_linear;

    // --- ЛОГИКА СКАЙЛАЙНОВ ---
    if (skyline_width > 0) {
        // Вычисляем текущую строку с высокой точностью
        // Используем frac для определения положения внутри цикла
        float pixel_y = texcoord.y * BUFFER_HEIGHT;
        // Находим положение внутри цикла длиной (2 * skyline_width)
        // Умножаем на (2 * skyline_width), сдвигаем на 0.5 для корректного "окна" скайлайна, затем берем дробную часть
        float cycle_pos = frac(pixel_y * (1.0 / (2.0 * float(skyline_width))) + 0.5); // +0.5 может сдвинуть паттерн, если нужно
        // Теперь cycle_pos изменяется от 0 до 1 в пределах одного цикла
        // "Окно" скайлайна занимает долю (float(skyline_width) / (2.0 * float(skyline_width))) = 0.5 от этого цикла
        // Но проще использовать умножение: cycle_pos * (2 * skyline_width) даст номер "строки" внутри цикла
        float scaled_pos = cycle_pos * (2.0 * float(skyline_width));
        // Проверяем, попадает ли позиция в "окно" скайлайна (от 0 до skyline_width)
        // Используем floor для получения целого номера "строки" в цикле
        int cycle_row = int(floor(scaled_pos)); // floor более предсказуем, чем int() для положительных чисел

        // Если номер строки в цикле меньше ширины скайлайна, строка затемнена
        bool is_skyline_row = (cycle_row < skyline_width);

        if (is_skyline_row) {
            // Применяем коэффициент блокировки
            modifiedColor_linear *= skyline_block_coeff;
        } else {
            // Применяем стандартные потери маски и усиление к НЕ-скайлайн строкам
            modifiedColor_linear = modifiedColor_linear * (1.0 - mask_brightness_loss) * pre_boost;
        }
    } else {
        // Если скайлайны отключены, применяем стандартные потери и усиление ко всем строкам
        modifiedColor_linear = modifiedColor_linear * (1.0 - mask_brightness_loss) * pre_boost;
    }
    // --- КОНЕЦ ЛОГИКИ СКАЙЛАЙНОВ ---

    // Если строка скайлайн, стандартные потери и усиление НЕ применяются,
    // и цвет уже изменён на этой строке (modifiedColor_linear *= skyline_block_coeff;)

    return float4(saturate(modifiedColor_linear), 1.0);
}
// === ПРОХОД 4: МЕЖПИКСЕЛЬНОЕ РАЗМЫТИЕ (ОПТИКА CRT) ===
float4 Pass4_ApplyInterPixelBlur(float4 pos : SV_Position, float2 texcoord : TEXCOORD0) : SV_Target
{
    float2 texsize = float2(BUFFER_WIDTH, BUFFER_HEIGHT);
    float3 blurred = graphBasedBlur2Level(AccumASampler, texcoord, texsize, max(inter_blur, 0.001));
    return float4(blurred, 1.0);
}

float4 Pass5_CopyMaskedBlurred(float4 vpos : SV_Position, float2 texcoord : TexCoord) : SV_Target
{
    return tex2D(AccumBSampler, texcoord);
}

// === ФИНАЛЬНЫЙ ПРОХОД: ВЫСОКОКАЧЕСТВЕННОЕ ОПТИЧЕСКОЕ СВЕЧЕНИЕ ===
float4 Pass8_DisplayWithHighQualityGlow(float4 vpos : SV_Position, float2 texcoord : TexCoord) : SV_Target
{
    float3 final_linear = tex2D(AccumASampler, texcoord).rgb;

    // === 1. Выделение ярких областей с нелинейностью ===
    float3 bright = max(0.0, final_linear - glow_threshold);
    bright = pow(bright, 1.6); // нелинейное усиление пересвета

    // === 2. Параметры размытия (в пикселях) ===
    float2 texel = float2(BUFFER_RCP_WIDTH, BUFFER_RCP_HEIGHT);
   // const float near_radius = 5.0;   // ближнее свечение
   // const float far_radius  = 25.0;  // дальнее свечение
    const float near_weight = 0.8;
    const float far_weight  = 0.3;

    // === 3. Near Glow: гауссово размытие (точное, 5×5) ===
    float3 near_glow = 0.0;
    float near_sum = 0.0;
    for (int dy = -2; dy <= 2; dy++)
    for (int dx = -2; dx <= 2; dx++)
    {
        float d2 = float(dx*dx + dy*dy);
        float w = exp(-d2 / (2.0 * near_radius * near_radius / 4.0)); // sigma = radius/2
        float3 sample2 = tex2D(AccumASampler, texcoord + float2(dx, dy) * texel).rgb;
        near_glow += max(0.0, sample2 - glow_threshold) * w;
        near_sum += w;
    }
    near_glow = (near_glow / max(near_sum, 1e-5)) * near_weight;

    // === 4. Far Bloom: крупное размытие (7×7 box → приближает гаусс) ===
    float3 far_glow = 0.0;
    float far_sum = 0.0;
    const int R = 3;
    for (int dy = -R; dy <= R; dy++)
    for (int dx = -R; dx <= R; dx++)
    {
        float w = 1.0;
        float3 sample2 = tex2D(AccumASampler, texcoord + float2(dx, dy) * texel * (far_radius / R)).rgb;
        far_glow += max(0.0, sample2 - glow_threshold) * w;
        far_sum += w;
    }
    far_glow = (far_glow / max(far_sum, 1e-5)) * far_weight;

    // === 5. Объединение и десатурация ===
    float3 glow = (near_glow + far_glow) * glow_strength;

    // Тепловая десатурация (имитация стекла CRT)
    float glow_lum = dot(glow, float3(0.25, 0.65, 0.1)); // зелёный акцент
    glow = lerp(glow, glow_lum.xxx, 0.3);

    // === 6. Финальный вывод ===
    float3 display_linear = (final_linear + glow) * OutputGain;
    float3 display_srgb = pow(saturate(display_linear), 1.0 / crt_gamma);
    return float4(display_srgb, 1.0);
}
// === ТЕХНИКА ===
technique ShadowCRT
{
    pass UpdatePersistence
    {
        VertexShader = PostProcessVS;
        PixelShader = Pass1_UpdatePersistence;
        RenderTarget = AccumB;
    }
    pass CopyPersistence
    {
        VertexShader = PostProcessVS;
        PixelShader = Pass2_CopyPersistence;
        RenderTarget = AccumA;
    }
    pass ApplyShadowMask
    {
        VertexShader = PostProcessVS;
        PixelShader = Pass3_ApplyShadowMask;
        RenderTarget = AccumB;
    }
    pass CopyMaskedResult
    {
        VertexShader = PostProcessVS;
        PixelShader = Pass5_CopyMaskedBlurred;
        RenderTarget = AccumA;
    }
    pass ApplyInterPixelBlur
    {
        VertexShader = PostProcessVS;
        PixelShader = Pass4_ApplyInterPixelBlur;
        RenderTarget = AccumB;
    }
    pass CopyMaskedBlurredResult
    {
        VertexShader = PostProcessVS;
        PixelShader = Pass5_CopyMaskedBlurred;
        RenderTarget = AccumA;
    }
    pass DisplayWithPSFGlow
    {
        VertexShader = PostProcessVS;
        PixelShader = Pass8_DisplayWithHighQualityGlow;
    }
}