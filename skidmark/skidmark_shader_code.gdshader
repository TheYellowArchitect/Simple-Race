shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;

uniform sampler2D albedo_texture : source_color, filter_linear_mipmap, repeat_enable;
uniform float uv_scale : hint_range(0.01, 50.0) = 10.0;

void fragment() {
    vec4 tex = texture(albedo_texture, vec2(UV.x, UV.y / uv_scale));
    ALBEDO = COLOR.rgb * tex.rgb;
    ALPHA = COLOR.a; //* tex.a;
}