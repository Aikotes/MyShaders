// CRT Sedimentation Shader for ReShade FX 6.1.1
// Three-pass implementation: Height Maps -> Sedimentation -> Composite

uniform int u_radius <
    ui_type = "slider";
    ui_min = 1; 
    ui_max = 5;
    ui_step = 1;
    ui_label = "Simulation Radius";
    ui_tooltip = "Higher = more blur, lower = better performance";
> = 3;

uniform int u_iterations <
    ui_type = "slider";
    ui_min = 1; 
    ui_max = 20;
    ui_step = 1;
    ui_label = "Iteration Count";
    ui_tooltip = "More iterations = stronger effect";
> = 8;

uniform float u_flow_rate <
    ui_type = "slider";
    ui_min = 0.01; 
    ui_max = 0.3;
    ui_step = 0.01;
    ui_label = "Flow Rate";
    ui_tooltip = "How fast particles move between pixels";
> = 0.15;

uniform float u_channel_offset_r <
    ui_type = "slider";
    ui_min = -0.005; 
    ui_max = 0.005;
    ui_step = 0.0001;
    ui_label = "Red Channel Offset";
    ui_tooltip = "CRT color convergence simulation";
> = 0.001;

uniform float u_channel_offset_g <
    ui_type = "slider";
    ui_min = -0.005; 
    ui_max = 0.005;
    ui_step = 0.0001;
    ui_label = "Green Channel Offset";
> = 0.0;

uniform float u_channel_offset_b <
    ui_type = "slider";
    ui_min = -0.005; 
    ui_max = 0.005;
    ui_step = 0.0001;
    ui_label = "Blue Channel Offset";
> = -0.001;

// Texture declarations for intermediate passes
texture2D texHeightMapR { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA8; };
texture2D texHeightMapG { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA8; };
texture2D texHeightMapB { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA8; };

texture2D texProcessedR { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA8; };
texture2D texProcessedG { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA8; };
texture2D texProcessedB { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA8; };

// Samplers for the textures
sampler2D samplerHeightMapR { Texture = texHeightMapR; };
sampler2D samplerHeightMapG { Texture = texHeightMapG; };
sampler2D samplerHeightMapB { Texture = texHeightMapB; };

sampler2D samplerProcessedR { Texture = texProcessedR; };
sampler2D samplerProcessedG { Texture = texProcessedG; };
sampler2D samplerProcessedB { Texture = texProcessedB; };

// Main backbuffer sampler - CORRECT FOR ReShade 6.1.1
texture2D BackBufferTex : COLOR;
sampler2D ReShadeBackBuffer { Texture = BackBufferTex; };

// Utility function to get pixel size
float2 get_pixel_size()
{
    return float2(BUFFER_RCP_WIDTH, BUFFER_RCP_HEIGHT);
}

// Simple vertex shader for fullscreen quad
void FullscreenVS(in uint id : SV_VertexID, out float4 pos : SV_Position, out float2 texcoord : TEXCOORD)
{
    texcoord.x = (id == 2) ? 2.0 : 0.0;
    texcoord.y = (id == 1) ? 2.0 : 0.0;
    pos = float4(texcoord * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
}

// Pass 1: Create Height Maps
float4 Pass1_PS(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
    float2 pixel_size = get_pixel_size();
    
    // Apply channel offsets for CRT convergence effect
    float2 texcoord_r = texcoord + float2(u_channel_offset_r, 0.0);
    float2 texcoord_g = texcoord + float2(u_channel_offset_g, 0.0); 
    float2 texcoord_b = texcoord + float2(u_channel_offset_b, 0.0);
    
    // Sample original texture with offsets - CORRECT SYNTAX
    float3 color = tex2D(ReShadeBackBuffer, texcoord).rgb;
    float color_r = tex2D(ReShadeBackBuffer, texcoord_r).r;
    float color_g = tex2D(ReShadeBackBuffer, texcoord_g).g;
    float color_b = tex2D(ReShadeBackBuffer, texcoord_b).b;
    
    // Output separate height maps for each channel
    return float4(color_r, color_g, color_b, 1.0);
}

// Pass 1 for individual channels (simplified)
float4 Pass1_R_PS(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
    float2 texcoord_r = texcoord + float2(u_channel_offset_r, 0.0);
    float color_r = tex2D(ReShadeBackBuffer, texcoord_r).r;
    return float4(color_r, color_r, color_r, 1.0);
}

float4 Pass1_G_PS(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
    float2 texcoord_g = texcoord + float2(u_channel_offset_g, 0.0);
    float color_g = tex2D(ReShadeBackBuffer, texcoord_g).g;
    return float4(color_g, color_g, color_g, 1.0);
}

float4 Pass1_B_PS(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
    float2 texcoord_b = texcoord + float2(u_channel_offset_b, 0.0);
    float color_b = tex2D(ReShadeBackBuffer, texcoord_b).b;
    return float4(color_b, color_b, color_b, 1.0);
}

// Pass 2: Sedimentation Simulation
float4 sedimentation_ps(float4 pos : SV_Position, float2 texcoord : TEXCOORD,  sampler2D input_sampler) : SV_Target
{
    float2 pixel_size = get_pixel_size();
    int radius = u_radius;
    
    // Sample center pixel
    float center_height = tex2D(input_sampler, texcoord).r;
    
    // Initialize accumulation
    float total_outflow = 0.0;
    float height_change = 0.0;
    
    int samples = 0;
    
    // Sample neighbors in a radius
    for (int y = -radius; y <= radius; y++)
    {
        for (int x = -radius; x <= radius; x++)
        {
            // Skip center pixel
            if (x == 0 && y == 0)
                continue;
                
            float2 neighbor_texcoord = texcoord + float2(x, y) * pixel_size;
            float neighbor_height = tex2D(input_sampler, neighbor_texcoord).r;
            
            // Calculate height difference
            float height_diff = center_height - neighbor_height;
            
            // Only flow from higher to lower areas
            if (height_diff > 0.0)
            {
                // Flow amount based on difference and distance
                float distance = length(float2(x, y));
                float distance_factor = 1.0 / (distance + 1.0);
                float flow = height_diff * u_flow_rate * distance_factor * 0.1;
                
                total_outflow += flow;
                samples++;
            }
        }
    }
    
    // Average the outflow
    if (samples > 0)
    {
        total_outflow /= samples;
    }
    
    // Apply the sedimentation effect
    float new_height = center_height - total_outflow;
    
    // Clamp to valid range
    new_height = clamp(new_height, 0.0, 1.0);
    
    return float4(new_height, new_height, new_height, 1.0);
}

// Individual sedimentation passes for each channel
float4 Pass2_R_PS(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
    return sedimentation_ps(pos, texcoord, samplerHeightMapR);
}

float4 Pass2_G_PS(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
    return sedimentation_ps(pos, texcoord, samplerHeightMapG);
}

float4 Pass2_B_PS(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
    return sedimentation_ps(pos, texcoord, samplerHeightMapB);
}

// Pass 3: Composite final image
float4 Pass3_PS(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
    // Sample the processed height maps
    float r_height = tex2D(samplerProcessedR, texcoord).r;
    float g_height = tex2D(samplerProcessedG, texcoord).r;
    float b_height = tex2D(samplerProcessedB, texcoord).r;
    
    // Reconstruct final color from height maps
    float3 final_color = float3(r_height, g_height, b_height);
    
    // Optional: Add some CRT-style bloom/vibrance
    final_color = saturate(final_color * 1.05 - 0.025);
    
    return float4(final_color, 1.0);
}

// Simplified version with single-pass sedimentation
float4 Pass_Combined_PS(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
    float2 pixel_size = get_pixel_size();
    
    // Sample with channel offsets
    float2 texcoord_r = texcoord + float2(u_channel_offset_r, 0.0);
    float2 texcoord_g = texcoord + float2(u_channel_offset_g, 0.0); 
    float2 texcoord_b = texcoord + float2(u_channel_offset_b, 0.0);
    
    float r_center = tex2D(ReShadeBackBuffer, texcoord_r).r;
    float g_center = tex2D(ReShadeBackBuffer, texcoord_g).g;
    float b_center = tex2D(ReShadeBackBuffer, texcoord_b).b;
    
    // Simple sedimentation for each channel
    float3 outflow = float3(0.0, 0.0, 0.0);
    int radius = 2;
    int samples = 0;
    
    for (int y = -radius; y <= radius; y++)
    {
        for (int x = -radius; x <= radius; x++)
        {
            if (x == 0 && y == 0) continue;
            
            float2 neighbor_texcoord = texcoord + float2(x, y) * pixel_size;
            float3 neighbor_color = tex2D(ReShadeBackBuffer, neighbor_texcoord).rgb;
            
            float3 height_diff = float3(r_center, g_center, b_center) - neighbor_color;
            
            if (height_diff.r > 0.0) outflow.r += height_diff.r * u_flow_rate * 0.05;
            if (height_diff.g > 0.0) outflow.g += height_diff.g * u_flow_rate * 0.05;
            if (height_diff.b > 0.0) outflow.b += height_diff.b * u_flow_rate * 0.05;
            
            samples++;
        }
    }
    
    if (samples > 0)
    {
        outflow /= samples;
    }
    
    float3 final_color = float3(r_center, g_center, b_center) - outflow;
    final_color = saturate(final_color);
    
    return float4(final_color, 1.0);
}

// Technique definitions
technique CRT_Sedimentation
{
    // Version 1: Full three-pass with separate channels
    pass Create_HeightMaps_R
    {
        VertexShader = FullscreenVS;
        PixelShader = Pass1_R_PS;
        RenderTarget0 = texHeightMapR;
    }
    
    pass Create_HeightMaps_G
    {
        VertexShader = FullscreenVS;
        PixelShader = Pass1_G_PS;
        RenderTarget0 = texHeightMapG;
    }
    
    pass Create_HeightMaps_B
    {
        VertexShader = FullscreenVS;
        PixelShader = Pass1_B_PS;
        RenderTarget0 = texHeightMapB;
    }
    
    pass Sedimentation_Red
    {
        VertexShader = FullscreenVS;
        PixelShader = Pass2_R_PS;
        RenderTarget0 = texProcessedR;
    }
    
    pass Sedimentation_Green
    {
        VertexShader = FullscreenVS;
        PixelShader = Pass2_G_PS;
        RenderTarget0 = texProcessedG;
    }
    
    pass Sedimentation_Blue
    {
        VertexShader = FullscreenVS;
        PixelShader = Pass2_B_PS;
        RenderTarget0 = texProcessedB;
    }
    
    pass Composite_Final
    {
        VertexShader = FullscreenVS;
        PixelShader = Pass3_PS;
    }
}

// Version 2: Simplified single-pass technique (better performance)
technique CRT_Sedimentation_Fast
{
    pass Combined_Sedimentation
    {
        VertexShader = FullscreenVS;
        PixelShader = Pass_Combined_PS;
    }
}

// Version 3: Multi-pass with single height map creation
technique CRT_Sedimentation_Standard
{
    pass Create_AllHeightMaps
    {
        VertexShader = FullscreenVS;
        PixelShader = Pass1_PS;
        RenderTarget0 = texHeightMapR;
        RenderTarget1 = texHeightMapG;
        RenderTarget2 = texHeightMapB;
    }
    
    pass Process_Red
    {
        VertexShader = FullscreenVS;
        PixelShader = Pass2_R_PS;
        RenderTarget0 = texProcessedR;
    }
    
    pass Process_Green
    {
        VertexShader = FullscreenVS;
        PixelShader = Pass2_G_PS;
        RenderTarget0 = texProcessedG;
    }
    
    pass Process_Blue
    {
        VertexShader = FullscreenVS;
        PixelShader = Pass2_B_PS;
        RenderTarget0 = texProcessedB;
    }
    
    pass Composite
    {
        VertexShader = FullscreenVS;
        PixelShader = Pass3_PS;
    }
}