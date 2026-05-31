## TODO: Code review, experimental feature

extends Node3D
class_name SkidmarkMesh

const MAX_POINTS = 4096  # per-trail cap
const MARK_WIDTH = 0.3
const FADE_TIME = 10.0
const TAIL_FADE_POINTS = 8   # feather alpha over the last N points when a strip ends
const STRIP_END_GRACE = 0.4  # seconds without a new point before a strip is finalized

const SKIDMARK_OFFSET_X := 0.1

class SkidPoint:
	var pos: Vector3
	var normal: Vector3
	var forward: Vector3
	var speed_factor: float
	var time_created: float
	var strip_start: bool
	var tail_fade: float = 1.0
	
	func _init(p_pos: Vector3, p_normal: Vector3, p_forward: Vector3, p_speed: float, p_time: float, p_start: bool):
		pos = p_pos
		normal = p_normal
		forward = p_forward
		speed_factor = p_speed
		time_created = p_time
		strip_start = p_start

var array_mesh: ArrayMesh
@onready var mesh_instance: MeshInstance3D = $MeshInstance3D

# One independent trail per wheel, keyed by the wheel's instance id.
var trails: Dictionary = {}

var vertices := PackedVector3Array()
var colors := PackedColorArray()

func _ready() -> void:
	# Reset to identity to put it at the world origin.
	mesh_instance.top_level = true
	mesh_instance.global_transform = Transform3D.IDENTITY
	array_mesh = mesh_instance.mesh
	
	var mat = StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh_instance.material_override = mat

func _get_trail(wheel_id: int) -> Dictionary:
	if not trails.has(wheel_id):
		trails[wheel_id] = {
			"points": [] as Array[SkidPoint],
			"is_active_strip": false,
			"last_stamp_pos": Vector3.ZERO,
			"current_strip_length": 0.0,
			"last_stamp_time": 0.0,
		}
	return trails[wheel_id]

func _try_make_skidmark(wheel: Node3D, wheel_forward_dir: Vector3, slip_angle_norm: float, car_speed_kph: float) -> void:
	var space_state = get_world_3d().direct_space_state
	var up := global_basis.y
	var query = PhysicsRayQueryParameters3D.create(
		wheel.global_position + up * 0.2,
		wheel.global_position - up * 0.5
	)
	query.exclude = [self, wheel, wheel.get_parent()]
	var result = space_state.intersect_ray(query)
	if result:
		var hit_pos: Vector3 = result.position
		hit_pos += global_basis.x * signf(to_local(hit_pos).x) * SKIDMARK_OFFSET_X
		try_stamp(wheel.get_instance_id(), hit_pos, wheel_forward_dir, result.normal, car_speed_kph, slip_angle_norm)

func try_stamp(wheel_id: int, wheel_position: Vector3, wheel_forward: Vector3, normal: Vector3, speed: float, slip_angle_norm: float) -> void:
	var trail := _get_trail(wheel_id)
	var speed_factor := clampf(abs(speed) / 60.0, 0.0, 1.0)
	var slip_factor := clampf(slip_angle_norm / 0.1, 0.0, 1.0)
	var intensity := speed_factor * slip_factor
	
	if intensity < 0.05:
		end_strip(trail)
		return
		
	trail.last_stamp_time = Time.get_ticks_msec() / 1000.0
	if wheel_position.distance_to(trail.last_stamp_pos) >= MARK_WIDTH * 0.3:
		_add_point(trail, wheel_position, wheel_forward, normal, intensity)
		trail.last_stamp_pos = wheel_position

func end_strip(trail: Dictionary) -> void:
	if trail.is_active_strip:
		_taper_strip_tail(trail)
		_rebuild_mesh()
	trail.is_active_strip = false
	trail.current_strip_length = 0.0

func _taper_strip_tail(trail: Dictionary) -> void:
	var pts: Array[SkidPoint] = trail.points
	var tail_count := mini(TAIL_FADE_POINTS, int(trail.current_strip_length))
	if tail_count < 2:
		return
	var n := pts.size()
	for k in range(tail_count):
		pts[n - tail_count + k].tail_fade = 1.0 - float(k) / float(tail_count - 1)

func _add_point(trail: Dictionary, pos: Vector3, forward: Vector3, normal: Vector3, intensity: float) -> void:
	trail.current_strip_length += 1
	var fade_in := clampf(trail.current_strip_length / 5.0, 0.0, 1.0)
	var time_created := Time.get_ticks_msec() / 1000.0
	var is_start: bool = not trail.is_active_strip

	var point = SkidPoint.new(pos, normal, forward, intensity * fade_in, time_created, is_start)
	trail.points.append(point)
	trail.is_active_strip = true

	if trail.points.size() > MAX_POINTS:
		trail.points.pop_front()
		_rebuild_mesh()
	else:
		_append_last_quad(trail)

func _append_last_quad(trail: Dictionary) -> void:
	var pts: Array[SkidPoint] = trail.points
	var i := pts.size() - 1
	if i < 1:
		return
		
	var a: SkidPoint = pts[i - 1]
	var b: SkidPoint = pts[i]
	
	if b.strip_start:
		_upload_mesh()
		return

	var right_a: Vector3 = a.forward.cross(a.normal).normalized() * MARK_WIDTH * 0.5 * a.speed_factor
	var right_b: Vector3 = b.forward.cross(b.normal).normalized() * MARK_WIDTH * 0.5 * b.speed_factor
	_emit_quad(a, b, right_a, right_b, Time.get_ticks_msec() / 1000.0)
	_upload_mesh()

func _rebuild_mesh() -> void:
	vertices.clear()
	colors.clear()

	var now: float = Time.get_ticks_msec() / 1000.0
	for wheel_id in trails:
		var trail: Dictionary = trails[wheel_id]
		var pts: Array[SkidPoint] = trail.points

		var rights: Array[Vector3] = []
		for p in pts:
			rights.append(p.forward.cross(p.normal).normalized() * MARK_WIDTH * 0.5 * p.speed_factor)
			
		var smooth_rights: Array[Vector3] = []
		for i in range(pts.size()):
			if i == 0 or i == pts.size() - 1:
				smooth_rights.append(rights[i])
			else:
				var avg_right = (rights[i - 1] + rights[i] + rights[i + 1]).normalized()
				smooth_rights.append(avg_right * MARK_WIDTH * 0.5 * pts[i].speed_factor)

		for i in range(1, pts.size()):
			var a = pts[i - 1]
			var b = pts[i]
			if b.strip_start:
				continue
			_emit_quad(a, b, smooth_rights[i - 1], smooth_rights[i], now)

	_upload_mesh()

func _emit_quad(a: SkidPoint, b: SkidPoint, right_a: Vector3, right_b: Vector3, now: float) -> void:
	var offset_a: Vector3 = a.normal * 0.02
	var offset_b: Vector3 = b.normal * 0.02

	var a_left: Vector3 = a.pos - right_a + offset_a
	var a_right: Vector3 = a.pos + right_a + offset_a
	var b_left: Vector3 = b.pos - right_b + offset_b
	var b_right: Vector3 = b.pos + right_b + offset_b

	var brightness := lerpf(0.4, 0.15, a.speed_factor)
	var age: float = now - a.time_created
	var alpha: float = clampf(1.0 - (age / FADE_TIME), 0.0, 1.0) * a.speed_factor * a.tail_fade
	var c := Color(brightness, brightness, brightness, alpha)

	# Triangle 1
	colors.append(c); vertices.append(a_left)
	colors.append(c); vertices.append(b_left)
	colors.append(c); vertices.append(a_right)
	# Triangle 2
	colors.append(c); vertices.append(a_right)
	colors.append(c); vertices.append(b_left)
	colors.append(c); vertices.append(b_right)

func _upload_mesh() -> void:
	array_mesh.clear_surfaces()
	if vertices.is_empty():
		return
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_COLOR] = colors
	array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

var rebuild_timer := 0.0

func _process(delta: float) -> void:
	var now: float = Time.get_ticks_msec() / 1000.0

	for wid in trails:
		var trail: Dictionary = trails[wid]
		if trail.is_active_strip and now - trail.last_stamp_time > STRIP_END_GRACE:
			end_strip(trail)

	rebuild_timer += delta
	if rebuild_timer >= 0.5:
		_rebuild_mesh()
		rebuild_timer = 0.0 
		
	for wid in trails:
		trails[wid].points = trails[wid].points.filter(func(p: SkidPoint):
			return (now - p.time_created) < FADE_TIME)
