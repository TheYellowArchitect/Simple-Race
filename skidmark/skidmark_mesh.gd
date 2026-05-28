extends Node3D
class_name SkidmarkMesh

const MAX_POINTS = 4096  # per-trail cap
const MARK_WIDTH = 0.3
const FADE_TIME = 10.0
const TAIL_FADE_POINTS = 8   # feather alpha over the last N points when a strip ends
const STRIP_END_GRACE = 0.4  # seconds without a new point before a strip is finalized

@export var skidmark_material: ShaderMaterial

var array_mesh: ArrayMesh
@onready var mesh_instance: MeshInstance3D = $MeshInstance3D

# One independent trail per wheel, keyed by the wheel's instance id.
# Each wheel MUST accumulate its own strip: feeding two rear wheels into one
# shared buffer stitches quads across the car (the "horizontal bars" bug).
var trails: Dictionary = {}

var vertices := PackedVector3Array()
var colors := PackedColorArray()
var uvs := PackedVector2Array()

func _ready() -> void:
	# the current global transform, so reset to identity to put it at the world origin.
	mesh_instance.global_transform = Transform3D.IDENTITY
	array_mesh = mesh_instance.mesh
	if (skidmark_material == null):
		push_error("Please assign a skidmark material.")
	mesh_instance.material_override = skidmark_material

func _get_trail(wheel_id: int) -> Dictionary:
	if not trails.has(wheel_id):
		trails[wheel_id] = {
			"points": [],
			"is_active_strip": false,
			"last_stamp_pos": Vector3.ZERO,
			"current_strip_length": 0.0,
			"uv_length": 0.0,
			"last_stamp_time": 0.0,
		}
	return trails[wheel_id]

func try_stamp(wheel_id: int, wheel_position: Vector3, wheel_forward: Vector3, normal: Vector3, speed: float, slip_angle_norm: float) -> void:
	var trail := _get_trail(wheel_id)
	var speed_factor := clampf(abs(speed) / 60.0, 0.0, 1.0)
	var slip_factor := clampf(slip_angle_norm / 0.1, 0.0, 1.0)  # 0.3 rad is strong slip, 0.1 is powerful
	var intensity := speed_factor * slip_factor
	if intensity < 0.05:
		end_strip(trail)
		return
	trail["last_stamp_time"] = Time.get_ticks_msec() / 1000.0  # keep strip alive while actively skidding
	if wheel_position.distance_to(trail["last_stamp_pos"]) >= MARK_WIDTH * 0.3:
		_add_point(trail, wheel_position, wheel_forward, normal, intensity)
		trail["last_stamp_pos"] = wheel_position

func end_strip(trail: Dictionary) -> void:
	if trail["is_active_strip"]:
		_taper_strip_tail(trail)  # feather the trailing end so it fades out instead of cutting off
		_rebuild_mesh()
	trail["is_active_strip"] = false
	trail["current_strip_length"] = 0.0

## Ramp the alpha of the last few points of the just-ended strip down to zero, so
## the tail feathers out instead of ending on a hard, fully-opaque edge.
func _taper_strip_tail(trail: Dictionary) -> void:
	var pts: Array = trail["points"]
	var tail := mini(TAIL_FADE_POINTS, int(trail["current_strip_length"]))
	if tail < 2:
		return
	var n := pts.size()
	for k in range(tail):
		pts[n - tail + k]["tail_fade"] = 1.0 - float(k) / float(tail - 1)

func _add_point(trail: Dictionary, pos: Vector3, forward: Vector3, normal: Vector3, intensity: float) -> void:
	trail["current_strip_length"] += 1
	var fade_in := clampf(trail["current_strip_length"] / 5.0, 0.0, 1.0)  # ramps over first 5 points
	trail["points"].append({
		"pos": pos,
		"normal": normal,
		"forward": forward,
		"speed_factor": intensity * fade_in,
		"time_created": Time.get_ticks_msec() / 1000.0,
		"strip_start": not trail["is_active_strip"],
		"tail_fade": 1.0,
	})
	trail["is_active_strip"] = true

	if trail["points"].size() > MAX_POINTS:
		trail["points"].pop_front()
		_rebuild_mesh()  # full rebuild only when ring buffer wraps
	else:
		_append_last_quad(trail)  # cheap: only add the new quad

func _append_last_quad(trail: Dictionary) -> void:
	var pts: Array = trail["points"]
	var i := pts.size() - 1
	if i < 1:
		return
	var a = pts[i - 1]
	var b = pts[i]
	if b["strip_start"]:
		trail["uv_length"] = 0.0
		_upload_mesh()
		return

	var right_a: Vector3 = a["forward"].cross(a["normal"]).normalized() * MARK_WIDTH * 0.5 * a["speed_factor"]
	var right_b: Vector3 = b["forward"].cross(b["normal"]).normalized() * MARK_WIDTH * 0.5 * b["speed_factor"]
	_emit_quad(trail, a, b, right_a, right_b, Time.get_ticks_msec() / 1000.0)
	_upload_mesh()

func _rebuild_mesh() -> void:
	vertices.clear()
	colors.clear()
	uvs.clear()

	var now: float = Time.get_ticks_msec() / 1000.0
	for wheel_id in trails:
		var trail: Dictionary = trails[wheel_id]
		trail["uv_length"] = 0.0
		var pts: Array = trail["points"]

		# Precompute smooth rights for this trail
		var rights: Array[Vector3] = []
		for p in pts:
			rights.append(p["forward"].cross(p["normal"]).normalized() * MARK_WIDTH * 0.5 * p["speed_factor"])
		var smooth_rights: Array[Vector3] = []
		for i in range(pts.size()):
			if i == 0 or i == pts.size() - 1:
				smooth_rights.append(rights[i])
			else:
				smooth_rights.append((rights[i - 1] + rights[i] + rights[i + 1]).normalized() * MARK_WIDTH * 0.5 * pts[i]["speed_factor"])

		for i in range(1, pts.size()):
			var a = pts[i - 1]
			var b = pts[i]
			if b["strip_start"]:
				trail["uv_length"] = 0.0
				continue
			_emit_quad(trail, a, b, smooth_rights[i - 1], smooth_rights[i], now)

	_upload_mesh()

## Appends one ribbon segment (two triangles) between points a and b into the
## shared vertex buffers. uv_length is tracked per-trail so the texture flows
## continuously along each wheel's own path.
func _emit_quad(trail: Dictionary, a: Dictionary, b: Dictionary, right_a: Vector3, right_b: Vector3, now: float) -> void:
	var offset_a: Vector3 = a["normal"] * 0.02
	var offset_b: Vector3 = b["normal"] * 0.02

	var a_left: Vector3 = a["pos"] - right_a + offset_a
	var a_right: Vector3 = a["pos"] + right_a + offset_a
	var b_left: Vector3 = b["pos"] - right_b + offset_b
	var b_right: Vector3 = b["pos"] + right_b + offset_b

	var segment_length: float = a["pos"].distance_to(b["pos"])
	var uv_a: float = trail["uv_length"]
	var uv_b: float = trail["uv_length"] + segment_length
	trail["uv_length"] += segment_length

	var brightness := lerpf(0.4, 0.15, a["speed_factor"])
	var age: float = now - a["time_created"]
	var alpha: float = clampf(1.0 - (age / FADE_TIME), 0.0, 1.0) * a["speed_factor"] * a.get("tail_fade", 1.0)
	var c := Color(brightness, brightness, brightness, alpha)

	# Triangle 1
	colors.append(c); uvs.append(Vector2(0.0, uv_a)); vertices.append(a_left)
	colors.append(c); uvs.append(Vector2(0.0, uv_b)); vertices.append(b_left)
	colors.append(c); uvs.append(Vector2(1.0, uv_a)); vertices.append(a_right)
	# Triangle 2
	colors.append(c); uvs.append(Vector2(1.0, uv_a)); vertices.append(a_right)
	colors.append(c); uvs.append(Vector2(0.0, uv_b)); vertices.append(b_left)
	colors.append(c); uvs.append(Vector2(1.0, uv_b)); vertices.append(b_right)

func _upload_mesh() -> void:
	array_mesh.clear_surfaces()
	if vertices.is_empty():
		return
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

func _process(_delta: float) -> void:
	#find_best_shader_UV()

	# Only rebuild periodically for fading, not every frame
	var now: float = Time.get_ticks_msec() / 1000.0

	# Finalize strips that stopped receiving points (lifted off L2, straightened,
	# or stopped) so their tails feather out via end_strip's taper.
	for wid in trails:
		var trail: Dictionary = trails[wid]
		if trail["is_active_strip"] and now - trail["last_stamp_time"] > STRIP_END_GRACE:
			end_strip(trail)

	if fmod(now, 0.5) < 0.016:  # roughly every 0.5 seconds
		_rebuild_mesh()
	# Clean up fully faded points, per trail
	for wid in trails:
		trails[wid]["points"] = trails[wid]["points"].filter(func(p):
			return (now - p["time_created"]) < FADE_TIME)

## Each texture has its own best UV Scale value in the shader parameter.
## This is the fastest way to test this realtime instead of rebooting the editor or even alt-tabbing to it.
func find_best_shader_UV() -> void:
	if Input.is_action_just_pressed("ui_accept"):
		var mat: ShaderMaterial = mesh_instance.material_override as ShaderMaterial
		mat.set_shader_parameter("uv_scale", mat.get_shader_parameter("uv_scale") + 0.1)
		print("uv_scale: ", mat.get_shader_parameter("uv_scale"))
	if Input.is_action_just_pressed("ui_cancel"):
		var mat: ShaderMaterial = mesh_instance.material_override as ShaderMaterial
		mat.set_shader_parameter("uv_scale", maxf(0.1, mat.get_shader_parameter("uv_scale") - 0.1))
		print("uv_scale: ", mat.get_shader_parameter("uv_scale"))
