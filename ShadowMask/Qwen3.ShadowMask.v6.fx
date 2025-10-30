#include "reshade.fxh"

// === ПАРАМЕТРЫ SHADOWMASK (из v4) ===
uniform float pre_boost <
    ui_label = "Предусиление яркости (SM)";
    ui_tooltip = "Усиление яркости до ослабления маской";
    ui_type = "slider";
    ui_min = 1.0;
    ui_max = 3.0;
    ui_step = 0.1;
> = 2.0;
uniform float mask_step <
    ui_label = "Шаг маски (SM)";
    ui_tooltip = "Расстояние между точками триады (в пикселях)";
    ui_type = "slider";
    ui_min = 0.5;
    ui_max = 3.0;
    ui_step = 0.1;
> = 0.9;
uniform float intra_blur <
    ui_label = "Внутрипиксельное размытие (SM)";
    ui_tooltip = "Сила влияния цветов внутри пикселя (каналы смешиваются)";
    ui_type = "slider";
    ui_min = 0.0;
    ui_max = 2.0;
    ui_step = 0.01;
> = 0.32;
uniform float inter_blur <
    ui_label = "Межпиксельное размытие (SM)";
    ui_tooltip = "Сила топологически корректного двухуровневого межпиксельного размытия, взвешенного по PSF фосфора";
    ui_type = "slider";
    ui_min = 0.0;
    ui_max = 2.0;
    ui_step = 0.01;
> = 0.23;
uniform float mask_brightness_loss <
    ui_label = "Потери в маске (SM)";
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
> = 0.9; // Параметр остался, но теперь для финального вывода
uniform float persistence <
    ui_label = "Послесвечение CRT (Final)";
    ui_tooltip = "Сила фосфорного послесвечения для финального изображения (0 = выкл)";
    ui_type = "slider";
    ui_min = 0.0;
    ui_max = 0.99;
    ui_step = 0.01;
> = 0.99;

// === ПАРАМЕТРЫ LASER (из v2) ===
uniform float laser_speed_per_frame <
    ui_label = "Скорость луча (Laser)";
    ui_tooltip = "Скорость движения луча за кадр";
    ui_type = "slider";
    ui_min = 0.0;
    ui_max = 10.0;
    ui_step = 0.1;
> = BUFFER_WIDTH;
uniform float laser_decay <
    ui_label = "Затухание луча (Laser)";
    ui_tooltip = "Скорость затухания послесвечения луча";
    ui_type = "slider";
    ui_min = 0.0;
    ui_max = 5.0;
    ui_step = 0.01;
> = 0.5;
uniform float laser_maxFrames <
    ui_label = "Макс. кадры луча (Laser)";
    ui_tooltip = "Максимальное время жизни эффекта луча";
    ui_type = "slider";
    ui_min = 1.0;
    ui_max = 100.0;
    ui_step = 1.0;
> = BUFFER_WIDTH*BUFFER_HEIGHT;
uniform float laser_brightness <
    ui_label = "Яркость луча (Laser)";
    ui_tooltip = "Базовая яркость эффекта послесвечения луча";
    ui_type = "slider";
    ui_min = 0.0;
    ui_max = 5.0;
    ui_step = 0.1;
> = 2.0;
uniform float laser_scanLine_per_frame <
    ui_label = "Шаг сканирования (Laser)";
    ui_tooltip = "Скорость движения луча по вертикали";
    ui_type = "slider";
    ui_min = 0.0;
    ui_max = 5.0;
    ui_step = 0.1;
> = 1.0;
uniform float laser_overlay_strength <
    ui_label = "Сила наложения (Laser)";
    ui_tooltip = "Насколько сильно налагается эффект луча на изображение";
    ui_type = "slider";
    ui_min = 0.0;
    ui_max = 1.0;
    ui_step = 0.01;
> = 0.3;

// === ТЕКСТУРЫ И СЭМПЛЕРЫ ===
// Основной входной источник
texture2D sourceTexture : COLOR;
// Текстуры для ShadowMask
texture2D intraInfluenceTexture { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA16F; };
texture2D smOutputTexture { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA16F; }; // Буфер после SM эффекта, перед Laser
// Текстуры для Laser
texture2D laserOutputTexture { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA16F; }; // Буфер после Laser эффекта
texture2D FrameCounterBuffer { Width = 1; Height = 1; Format = R32F; };
texture2D TempCounterBuffer { Width = 1; Height = 1; Format = R32F; };
// Текстуры для финального CRT (послесвечение и гамма)
texture2D persistenceBuffer { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA16F; };

// Сэмплеры
sampler2D sourceSampler { Texture = sourceTexture; };
sampler2D intraInfluenceSampler { Texture = intraInfluenceTexture; };
sampler2D smOutputSampler { Texture = smOutputTexture; };
sampler2D laserOutputSampler { Texture = laserOutputTexture; };
sampler2D FrameCounterSampler { Texture = FrameCounterBuffer; };
sampler2D TempCounterSampler { Texture = TempCounterBuffer; };
sampler2D persistenceSampler { Texture = persistenceBuffer; };

// --- Вспомогательная функция для вычисления гексагонального размытия (из ShadowMask v4) ---
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
    for (int i = 0; i < 6; i++) {
        float u = hex_offsets[i].x; float v = hex_offsets[i].y;
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
        hex_values[i] = lerp(lerp(I00, I10, f.x), lerp(I01, I11, f.x), f.y);
    }

    float w_neighbor_psf = exp(-1.0 / (2.0 * sigma_psf * sigma_psf));
    float3 neighbor_sum = hex_values[0] + hex_values[1] + hex_values[2] + hex_values[3] + hex_values[4] + hex_values[5];
    float3 total_neighbor_contribution = w_neighbor_psf * neighbor_sum;
    float w_center = 1.0;
    float total_weight = w_center + 6 * w_neighbor_psf;
    float3 normalized_blur = (w_center * center + total_neighbor_contribution) / total_weight;
    return normalized_blur;
}

// === ДВУХУРОВНЕВОЕ РАЗМЫТИЕ (Обновлённое) (из ShadowMask v4) ===
float3 graphBasedBlur2Level(float2 texcoord, float2 texsize)
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
         blurred_neighbors[i] = computeHexBlur(intraInfluenceSampler, local_texcoord, texsize, sigma_psf);
    }

    float3 center = tex2D(intraInfluenceSampler, texcoord).rgb;
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

// === ВНУТРИПИКСЕЛЬНОЕ ВЛИЯНИЕ (из ShadowMask v1) ===
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


// === ПИКСЕЛЬНЫЕ ШЕДЕРЫ SHADOWMASK ===
float4 Pass1_PS(float4 pos : SV_Position, float2 texcoord : TEXCOORD0) : SV_Target
{
    float2 texsize = float2(BUFFER_WIDTH, BUFFER_HEIGHT);
    float3 baseColor = tex2D(sourceSampler, texcoord).rgb;
    float3 intraColor = calculateIntraPixelInfluence(texcoord, texsize, baseColor);
    float3 finalColor = intraColor * (1.0 - mask_brightness_loss) * pre_boost;
    return float4(saturate(finalColor), 1.0);
}

float4 Pass2_PS(float4 pos : SV_Position, float2 texcoord : TEXCOORD0) : SV_Target
{
    float3 blurred = graphBasedBlur2Level(texcoord, float2(BUFFER_WIDTH, BUFFER_HEIGHT));
    return float4(blurred, 1.0);
}

// === ПИКСЕЛЬНЫЙ ШЕДЕР LASER ===
float4 PS_LaserEffect(float4 pos : SV_Position, float2 TexCoord : TEXCOORD0) : SV_Target
{
    float2 resolution = float2(BUFFER_WIDTH, BUFFER_HEIGHT);
    float screenWidth = resolution.x;
    float screenHeight = resolution.y;

    float frame_count = tex2D(FrameCounterSampler, float2(0.5, 0.5)).r;

    float temp_x = frame_count * laser_speed_per_frame;
    float x_current_px = temp_x - floor(temp_x / screenWidth) * screenWidth;
    float temp_y = frame_count * laser_speed_per_frame * laser_scanLine_per_frame;
    float y_current_px = temp_y - floor(temp_y / screenHeight) * screenHeight;

    float2 pixel_px = TexCoord * resolution;
    float2 delta_px = pixel_px - float2(x_current_px, y_current_px);

    if (delta_px.x > screenWidth * 0.5) delta_px.x -= screenWidth;
    if (delta_px.x < -screenWidth * 0.5) delta_px.x += screenWidth;
    if (delta_px.y > screenHeight * 0.5) delta_px.y -= screenHeight;
    if (delta_px.y < -screenHeight * 0.5) delta_px.y += screenHeight;

    float dist_px = length(delta_px);
    float frame_offset = dist_px / laser_speed_per_frame;

    float phos_brightness = exp(-laser_decay * frame_offset);
    if (frame_offset > laser_maxFrames) phos_brightness = 0.0;
    phos_brightness = max(0.0, phos_brightness);

    // Читаем из буфера, полученного после ShadowMask
    float4 original = tex2D(smOutputSampler, TexCoord);
    float3 glow = original.rgb * phos_brightness * laser_brightness;
    float3 final_rgb = original.rgb + glow * laser_overlay_strength;

    return float4(final_rgb, original.a);
}

// === ШЕЙДЕРЫ ОБНОВЛЕНИЯ СЧЁТЧИКА LASER ===
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

// === ПИКСЕЛЬНЫЕ ШЕДЕРЫ ФИНАЛЬНОГО CRT (Послесвечение и гамма) ===
float4 Pass3_UpdatePersistence(float4 pos : SV_Position, float2 texcoord : TEXCOORD0) : SV_Target
{
    // Читаем из буфера, полученного после Laser
    float3 current = tex2D(laserOutputSampler, texcoord).rgb;
    return float4(current, 1.0);
}

float4 Pass4_FinalOutput(float4 pos : SV_Position, float2 texcoord : TEXCOORD0) : SV_Target
{
    float3 current = tex2D(laserOutputSampler, texcoord).rgb;
    float3 previous = tex2D(persistenceSampler, texcoord).rgb;
    float3 persistent = lerp(current, previous, persistence);
    float3 final = pow(saturate(persistent), 1.0 / crt_gamma);
    return float4(final, 1.0);
}

// === ТЕХНИКА ===
technique Combined_ShadowMask_Laser_CRT
{
    // --- Этап 1: ShadowMask ---
    pass IntraPixelInfluence
    {
        VertexShader = PostProcessVS;
        PixelShader = Pass1_PS;
        RenderTarget = intraInfluenceTexture;
    }
    pass InterPixelGraphBlur2Level
    {
        VertexShader = PostProcessVS;
        PixelShader = Pass2_PS;
        RenderTarget = smOutputTexture; // Результат ShadowMask
    }

    // --- Этап 2: Обновление счётчика кадров для Laser ---
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

    // --- Этап 3: Применение Laser эффекта ---
    pass LaserEffect
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_LaserEffect;
        RenderTarget = laserOutputTexture; // Результат Laser, после SM
    }

    // --- Этап 4: Финальное CRT послесвечение и гамма ---
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