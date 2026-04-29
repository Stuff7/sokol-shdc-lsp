@header const m = @import("../math.zig")
@ctype mat4 m.Mat4

@vs vs
layout(binding = 0) uniform vs_params {
  mat4 mvp;
  mat4 sun_mvp;
  vec3 sun_direction;
};

in vec3 position;
in vec2 texcoord;
out vec2 frag_uv;
out vec3 frag_normal;

void main() {
  gl_Position = mvp * vec4(position, 1.0);
  frag_uv = texcoord;
  frag_normal = vec3(0.0);
}
@end

@fs fs
layout(binding = 0) uniform texture2D shadow_map;
layout(binding = 0) uniform sampler shadow_sampler;

in vec2 frag_uv;
in vec3 frag_normal;
out vec4 frag_color;

float xd(float a, float b, float c) {
  return a;
}

void main() {
  frag_color = texture(sampler2D(shadow_map, shadow_sampler), frag_uv);
  float x = xd(1,2, 2);
}
@end

@program chunk vs fs
