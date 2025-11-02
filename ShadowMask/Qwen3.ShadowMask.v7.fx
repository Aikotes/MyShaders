#include "reshade.fxh"

// === ОБЪЯВЛЕНИЕ 1x1 ТЕКСТУР ДЛЯ СЧЁТЧИКА КАДРОВ (из Laser.v2) ===
texture2D FrameCounterBuffer { Width = 1; Height = 1; Format = R32F; };
sampler2D FrameCounterSampler { Texture = FrameCounterBuffer; };
texture2D TempCounterBuffer { Width = 1; Height = 1; Format = R32F; };
sampler2D TempCounterSampler { Texture = TempCounterBuffer; };

// === ТЕКСТУРЫ И СЭМПЛЕРЫ (обновлены для пинг-понга) ===
texture2D sourceTexture : COLOR; // Входное изображение
texture2D intraInfluenceTexture { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA16F; };
// texture2D persistenceBuffer { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA16F; }; // Удалён
texture2D crtOutputTexture { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA16F; };
// sampler2D persistenceSampler { Texture = persistenceBuffer; }; // Удалён

// Новые буферы для пинг-понга
texture2D AccumA { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA16F; };
texture2D AccumB { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA16F; };
sampler2D AccumASampler { Texture = AccumA; };
sampler2D AccumBSampler { Texture = AccumB; };

sampler2D sourceSampler { Texture = sourceTexture; };
sampler2D intraInfluenceSampler { Texture = intraInfluenceTexture; };
sampler2D crtOutputSampler { Texture = crtOutputTexture; };

// === ПАРАМЕТРЫ (объединены из обоих шейдеров) ===
// Параметры для эффекта следа (из Laser.v2)
uniform float speed_per_frame <
    ui_label = "Скорость луча (пикс/кадр)";
    ui_tooltip = "Скорость движения луча по экрану (в пикселях за кадр)";
    ui_type = "slider";
    ui_min = 0.0;
    ui_max = BUFFER_WIDTH;
    ui_step = 0.1;
> = BUFFER_WIDTH;

uniform float decay <
    ui_label = "Затухание фосфора";
    ui_tooltip = "Скорость затухания светящегося следа (коэффициент экспоненты)";
    ui_type = "slider";
    ui_min = 0.0;
    ui_max = 5.0;
    ui_step = 0.01;
> = 0.5;

uniform float maxFrames <
    ui_label = "Макс. кадров следа";
    ui_tooltip = "Максимальное время жизни следа (в кадрах)";
    ui_type = "slider";
    ui_min = 1.0;
    ui_max = BUFFER_WIDTH*BUFFER_HEIGHT;
    ui_step = 1.0;
> = BUFFER_WIDTH*BUFFER_HEIGHT;

uniform float brightness <
    ui_label = "Яркость следа";
    ui_tooltip = "Множитель яркости для светящегося следа";
    ui_type = "slider";
    ui_min = 0.0;
    ui_max = 5.0;
    ui_step = 0.01;
> = 0.44;

uniform float scanLine_per_frame <
    ui_label = "Сканирование Y (пикс/кадр)";
    ui_tooltip = "Скорость движения луча по вертикали (в пикселях за кадр)";
    ui_type = "slider";
    ui_min = 0.0;
    ui_max = 10.0;
    ui_step = 0.01;
> = 1.0;

uniform float overlay_strength <
    ui_label = "Сила наложения следа";
    ui_tooltip = "Насколько сильно след влияет на изображение (0 = нет, 1 = полное наложение)";
    ui_type = "slider";
    ui_min = 0.0;
    ui_max = 1.0;
    ui_step = 0.01;
> = 0.30;

// Параметры для теневой маски (из ShadowMask.v4)
uniform float pre_boost <
    ui_label = "Предусиление яркости";
    ui_tooltip = "Усиление яркости до ослабления маской";
    ui_type = "slider";
    ui_min = 1.0;
    ui_max = 3.0;
    ui_step = 0.1;
> = 2.4;

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

uniform float crt_gamma <
    ui_label = "Гамма CRT";
    ui_tooltip = "Типичная гамма CRT-монитора (2.2–2.5)";
    ui_type = "slider";
    ui_min = 0.8;
    ui_max = 2.8;
    ui_step = 0.05;
> = 1.8;

// uniform float persistence < ... > = 0.99; // Удалён

// --- НОВЫЕ ПАРАМЕТРЫ ИЗ Persistence.txt ---
uniform float FPS < ui_type = "slider"; ui_min = 1.0; ui_max = 120.0; ui_step = 1.0; > = 4.0;
uniform float PersistenceR < ui_type = "drag"; ui_min = 0.01; ui_max = 1.0; ui_step = 0.01; > = 0.15;
uniform float PersistenceG < ui_type = "drag"; ui_min = 0.01; ui_max = 1.0; ui_step = 0.01; > = 0.15;
uniform float PersistenceB < ui_type = "drag"; ui_min = 0.01; ui_max = 1.0; ui_step = 0.01; > = 0.15;
uniform float InputGain     < ui_type = "drag"; ui_min = 0.0; ui_max = 2.0; ui_step = 0.01; > = 1.0;
uniform float OutputGain    < ui_type = "drag"; ui_min = 0.0; ui_max = 5.0; ui_step = 0.01; > = 1.12;
uniform float ResetThreshold< ui_type = "drag"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.01; > = 0.95;

// --- Вспомогательная функция для вычисления гексагонального размытия (из ShadowMask.v4) ---
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

    float w_neighbor_psf = exp(-1.0 / (2.0 * sigma_psf * sigma_psf));
    float3 neighbor_sum = hex_values[0] + hex_values[1] + hex_values[2] + hex_values[3] + hex_values[4] + hex_values[5];
    float3 total_neighbor_contribution = w_neighbor_psf * neighbor_sum;

    float w_center = 1.0;
    float total_weight = w_center + 6 * w_neighbor_psf;

    float3 normalized_blur = (w_center * center + total_neighbor_contribution) / total_weight;
    return normalized_blur;
}

// === ДВУХУРОВНЕВОЕ РАЗМЫТИЕ (из ShadowMask.v4) ===
float3 graphBasedBlur2Level(sampler2D input_sampler, float2 texcoord, float2 texsize) // Добавлен sampler как аргумент
{
    float sigma_psf = max(inter_blur, 0.001);
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
         blurred_neighbors[i] = computeHexBlur(input_sampler, local_texcoord, texsize, sigma_psf); // Используем переданный sampler
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
    float3 final_color = lerp(center, normalized_blur_2, saturate(inter_blur));
    return saturate(final_color);
}

// === ВНУТРИПИКСЕЛЬНОЕ ВЛИЯНИЕ (из ShadowMask.v4) ===
float3 calculateIntraPixelInfluence(float2 texcoord, float2 texsize, float3 baseColor, sampler2D input_sampler) // sampler как аргумент
{
    float2 pixelSize = 1.0 / texsize;
    float2 r_uv = float2(0.0, 0.0);
    float2 g_uv = float2(mask_step * pixelSize.x, 0.0);
    float2 b_uv = float2(0.5 * mask_step * pixelSize.x, 0.866 * mask_step * pixelSize.y);

    float r = tex2D(input_sampler, texcoord + r_uv).r;
    float g = tex2D(input_sampler, texcoord + g_uv).g;
    float b = tex2D(input_sampler, texcoord + b_uv).b;

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

// === ПРОХОД 0: Обновление счётчика кадров (из Laser.v2) ===
float4 Pass0_UpdateCounter(float4 pos : SV_Position, float2 texcoord : TEXCOORD0) : SV_Target
{
    float old_frame_count = tex2D(FrameCounterSampler, float2(0.5, 0.5)).r;
    float new_frame_count = old_frame_count + 1.0;
    return float4(new_frame_count, 0.0, 0.0, 1.0);
}

// === ПРОХОД 1: Применение эффекта светящегося следа к исходному изображению ===
float4 Pass1_AddLaserTrail(float4 pos : SV_Position, float2 TexCoord : TEXCOORD0) : SV_Target
{
    float2 resolution = float2(BUFFER_WIDTH, BUFFER_HEIGHT);
    float screenWidth = resolution.x;
    float screenHeight = resolution.y;
    float frame_count = tex2D(FrameCounterSampler, float2(0.5, 0.5)).r;
    float temp_x = frame_count * speed_per_frame;
    float x_current_px = temp_x - floor(temp_x / screenWidth) * screenWidth;
    float temp_y = frame_count * speed_per_frame * scanLine_per_frame;
    float y_current_px = temp_y - floor(temp_y / screenHeight) * screenHeight;

    float2 pixel_px = TexCoord * resolution;
    float2 delta_px = pixel_px - float2(x_current_px, y_current_px);
    if (delta_px.x > screenWidth * 0.5) delta_px.x -= screenWidth;
    if (delta_px.x < -screenWidth * 0.5) delta_px.x += screenWidth;
    if (delta_px.y > screenHeight * 0.5) delta_px.y -= screenHeight;
    if (delta_px.y < -screenHeight * 0.5) delta_px.y += screenHeight;

    float dist_px = length(delta_px);
    float frame_offset = dist_px / speed_per_frame;
    float phos_brightness = exp(-decay * frame_offset);
    if (frame_offset > maxFrames) phos_brightness = 0.0;
    phos_brightness = max(0.0, phos_brightness);

    float4 original = tex2D(sourceSampler, TexCoord);
    // Цветное свечение: используем оригинальный цвет пикселя
    float3 glow = original.rgb * phos_brightness * brightness;
    // Смешиваем: оригинальное изображение + аддитивный эффект с коэффициентом
    float3 result_with_trail = original.rgb + glow * overlay_strength;
    return float4(result_with_trail, original.a);
}

// === ПРОХОД 2: Внутрипиксельное влияние + ослабление маски (к результату с следом) ===
float4 Pass2_IntraPixelInfluence(float4 pos : SV_Position, float2 texcoord : TEXCOORD0) : SV_Target
{
    float2 texsize = float2(BUFFER_WIDTH, BUFFER_HEIGHT);
    // Читаем изображение с добавленным следом
    float3 baseColor = tex2D(crtOutputSampler, texcoord).rgb; // crtOutputTexture используется как промежуточный буфер
    float3 intraColor = calculateIntraPixelInfluence(texcoord, texsize, baseColor, crtOutputSampler); // Передаём sampler
    float3 finalColor = intraColor * (1.0 - mask_brightness_loss) * pre_boost;
    return float4(saturate(finalColor), 1.0);
}

// === ПРОХОД 3: Двухуровневое физически-взвешенное межпиксельное размытие (к результату с маской) ===
float4 Pass3_InterPixelGraphBlur2Level(float4 pos : SV_Position, float2 texcoord : TEXCOORD0) : SV_Target
{
    float2 texsize = float2(BUFFER_WIDTH, BUFFER_HEIGHT);
    // Читаем изображение с внутрипиксельным влиянием
    float3 blurred = graphBasedBlur2Level(intraInfluenceSampler, texcoord, texsize); // Передаём sampler
    return float4(blurred, 1.0);
}

// === ВСПОМОГАТЕЛЬНЫЙ ШЕЙДЕР КОПИРОВАНИЯ (из Laser.v2) ===
float4 PS_CopyTempToMain(float4 pos : SV_Position, float2 texcoord : TEXCOORD0) : SV_Target
{
    float new_frame_count = tex2D(TempCounterSampler, float2(0.5, 0.5)).r;
    return float4(new_frame_count, 0.0, 0.0, 1.0);
}

// === НОВЫЕ ПРОХОДЫ ДЛЯ ПОСЛЕСВЕЧЕНИЯ (из Persistence.txt, адаптированы) ===
// Проход 4: Обновление буфера послесвечения (читаем из crtOutput, пишем в AccumB)
float4 Pass4_UpdatePersistence(float4 vpos : SV_Position, float2 texcoord : TexCoord) : SV_Target
{
    // Читаем текущий кадр (уже обработанный через размытие) в линейном пространстве
    float3 current_srgb = tex2D(crtOutputSampler, texcoord).rgb;
    float3 current_linear = pow(current_srgb, 2.2);

    // Читаем историю из AccumA
    float3 history_linear = tex2D(AccumASampler, texcoord).rgb;

    // Параметры из Persistence.txt
    float dt = 1.0 / FPS;
    float3 tau = float3(PersistenceR, PersistenceG, PersistenceB);
    float3 alphas = exp(-dt / max(tau, 0.001));
    float3 decayed = history_linear * alphas;

    // Проверка сброса
    float avg_brightness = dot(current_linear, float3(0.2126, 0.7152, 0.0722));
    float3 new_history = (avg_brightness > ResetThreshold)
        ? current_linear * InputGain
        : decayed + current_linear * InputGain;

    new_history = min(new_history, 10.0); // Ограничение для стабильности
    return float4(new_history, avg_brightness);
}

// Проход 5: Копирование AccumB -> AccumA (для следующего кадра)
float4 Pass5_CopyPersistence(float4 vpos : SV_Position, float2 texcoord : TexCoord) : SV_Target
{
    return tex2D(AccumBSampler, texcoord);
}

// Проход 6: Вывод и гамма-коррекция (читаем из AccumB)
float4 Pass6_DisplayPersistence(float4 vpos : SV_Position, float2 texcoord : TexCoord) : SV_Target
{
    float3 accum_linear = tex2D(AccumBSampler, texcoord).rgb;
    float3 display_linear = accum_linear * OutputGain;
    // Применяем гамма-коррекцию CRT
    float3 display_srgb = pow(saturate(display_linear), 1.0 / crt_gamma);
    return float4(display_srgb, 1.0);
}

// === ТЕХНИКА ===
technique CRT_Laser_Trail_With_ShadowMask
{
    // Обновляем счётчик
    pass UpdateCounter
    {
        VertexShader = PostProcessVS;
        PixelShader = Pass0_UpdateCounter;
        RenderTarget = TempCounterBuffer;
    }
    // Копируем счётчик
    pass CopyTempToMain
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_CopyTempToMain; // Используем оригинальную функцию из Laser.v2
        RenderTarget = FrameCounterBuffer;
    }
    // Применяем след к исходному изображению -> crtOutputTexture
    pass AddLaserTrail
    {
        VertexShader = PostProcessVS;
        PixelShader = Pass1_AddLaserTrail;
        RenderTarget = crtOutputTexture; // Временный буфер для результата с лучом
    }
    // Применяем внутрипиксельное влияние и маску -> intraInfluenceTexture
    pass IntraPixelInfluence
    {
        VertexShader = PostProcessVS;
        PixelShader = Pass2_IntraPixelInfluence;
        RenderTarget = intraInfluenceTexture;
    }
    // Применяем межпиксельное размытие -> crtOutputTexture (переиспользуем)
    pass InterPixelGraphBlur2Level
    {
        VertexShader = PostProcessVS;
        PixelShader = Pass3_InterPixelGraphBlur2Level;
        RenderTarget = crtOutputTexture;
    }
    // Обновляем буфер послесвечения (AccumB) -> читаем из crtOutput, пишем в AccumB
    pass UpdatePersistence
    {
        VertexShader = PostProcessVS;
        PixelShader = Pass4_UpdatePersistence;
        RenderTarget = AccumB;
    }
    // Копируем AccumB -> AccumA
    pass CopyPersistence
    {
        VertexShader = PostProcessVS;
        PixelShader = Pass5_CopyPersistence;
        RenderTarget = AccumA;
    }
    // Финальный вывод с гаммой и послесвечением (читаем из AccumB)
    pass DisplayPersistence
    {
        VertexShader = PostProcessVS;
        PixelShader = Pass6_DisplayPersistence;
    }
}

