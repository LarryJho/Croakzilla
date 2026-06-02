shader_type canvas_item;

// flash=0 → original sprite, flash=1 → solid flash_color. Alpha preserved
// so transparent pixels stay transparent (no rectangular box).
// flash_color default = white para no romper el damage flash existente
// que no setea el uniform (lerp a blanco, comportamiento original).
uniform float flash : hint_range(0.0, 1.0) = 0.0;
uniform vec4 flash_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);

void fragment() {
	vec4 tex = texture(TEXTURE, UV);
	COLOR = vec4(mix(tex.rgb, flash_color.rgb, flash), tex.a);
}
