extends VehicleBody3D
## Drivable car. The obj car meshes have wheels BAKED into the body
## (single-material, single-surface), so the 4 VehicleWheel3D nodes stay
## invisible and just provide real raycast suspension/traction over them.
##
## Enter/exit: player.gd finds this car via the "cars" group and calls
## enter_player()/exit_player(). While occupied, the car forces the player's
## position to the seat and plays Driving_Loop.

const FORWARD_SIGN := -1.0      # model forward = local -Z (Godot convention). If the car drives backwards in-game, change to 1.0.
const ENGINE_FORCE := 2800.0    # Newtons! F/m with mass 650 = ~4.3 m/s2 acceleration
const REVERSE_FORCE := 1500.0
const BRAKE_FORCE := 150.0
const MAX_STEER := 0.55
const STEER_SPEED := 6.0
const SEAT_LOCAL := Vector3(-0.5, 0.92, 0.2)
const DOOR_OPEN_RAD := 1.05    # how far the cosmetic driver door swings (≈60°)

var _player = null               # untyped on purpose: cross-script dynamic calls
var _steer := 0.0
var _model: MeshInstance3D
var _box_half_x := 1.3           # half width of the auto-sized body collider (exit-margin base)
var _doors: Array[Node3D] = []   # cosmetic hinged door pivots: [0]=left(driver) [1]=right
var _door_busy := false
var _exiting := false

@onready var _box: CollisionShape3D = $CollisionShape3D
@onready var _loop: AudioStreamPlayer3D = $EngineLoop
@onready var _sfx: AudioStreamPlayer3D = $Sfx
@onready var _sfx2: AudioStreamPlayer3D = $Sfx2

var _loop_a: AudioStream
var _loop_b: AudioStream
var _snd_start: AudioStream
var _snd_stop: AudioStream
var _snd_door_open: AudioStream
var _snd_door_close: AudioStream
var _snd_horn: AudioStream


func _ready() -> void:
	add_to_group("cars")
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3(0, 0.25, 0)   # very low CoM: no flipping in corners or off curbs

	_loop_a = load("res://Sound effects/Car_Engine_Loop.ogg")
	_loop_b = load("res://Sound effects/Car2_Engine_Loop.ogg")
	for s in [_loop_a, _loop_b]:
		if s != null:
			s.loop = true
	_snd_start = load("res://Sound effects/Car2_Engine_Start_Up.ogg")
	_snd_stop = load("res://Sound effects/Car2_Engine_Turning_Off.ogg")
	_snd_door_open = load("res://Sound effects/Car_Door_Open.ogg")
	_snd_door_close = load("res://Sound effects/Car_Door_Close.ogg")
	_snd_horn = load("res://Sound effects/Car_Horn.ogg")

	_loop.stream = _loop_a
	_loop.max_distance = 50.0
	_sfx.max_distance = 50.0


## Called by car_spawner.gd: assigns the visual car mesh (obj import) and an
## optional livery texture; sizes the box collider from the mesh AABB.
func set_model(mesh: Mesh, livery: Texture2D) -> void:
	if _model == null:
		_model = MeshInstance3D.new()
		_model.name = "Model"
		$ModelRoot.add_child(_model)
	_model.mesh = mesh
	# The car's paint texture: livery override, else the obj's default MTL texture.
	var paint_tex: Texture2D = livery
	if paint_tex == null and mesh != null:
		var src := mesh.surface_get_material(0) as StandardMaterial3D
		if src != null:
			paint_tex = src.albedo_texture
	if mesh != null:
		var a: AABB = mesh.get_aabb()
		var bs := BoxShape3D.new()
		bs.size = Vector3(a.size.x * 0.92, a.size.y * 0.85, a.size.z * 0.98)
		_box.shape = bs
		_box.position = a.position + bs.size * 0.5
		_box_half_x = maxf(bs.size.x * 0.5, 1.2)
	if paint_tex != null and mesh != null:
		# Keep the imported look; liveries simply re-texture the same material.
		var src_mat := mesh.surface_get_material(0) as StandardMaterial3D
		var mat: StandardMaterial3D
		if src_mat != null:
			mat = src_mat.duplicate() as StandardMaterial3D
		else:
			mat = StandardMaterial3D.new()
		mat.albedo_texture = paint_tex
		_model.set_surface_override_material(0, mat)
	_spawn_door(paint_tex)


## --- enter / exit ---------------------------------------------------------
func enter_player(p) -> void:
	if _player != null or _door_busy:
		return
	_player = p
	p.enter_car(self)
	_door_busy = true
	# The door on the player's own side opens (left/driver is the default).
	var side := 0 if to_local(p.global_position).x <= 0.0 else 1
	var tw := create_tween()
	tw.tween_callback(_play_sfx.bind(_snd_door_open))
	tw.tween_property(_doors[side], "rotation:y", DOOR_OPEN_RAD * (1.0 if side == 0 else -1.0), 0.26) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tw.tween_callback(_seat_player.bind(p))
	tw.tween_callback(_play_sfx.bind(_snd_door_close))
	tw.tween_property(_doors[side], "rotation:y", 0.0, 0.3) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tw.tween_callback(_start_engine)
	tw.tween_callback(_release_door)


## Only when the door is fully open does the player "climb in" (snap to seat) —
## until then he stays visible standing by the car.
func _seat_player(p) -> void:
	if is_instance_valid(p):
		p.global_position = global_transform.translated_local(SEAT_LOCAL).origin
		if p.has_method("reset_physics_interpolation"):
			p.reset_physics_interpolation()


func exit_player() -> void:
	if _player == null or _door_busy:
		return
	_door_busy = true
	_exiting = true          # cut throttle while the exit animation plays
	var tw := create_tween()
	tw.tween_callback(_play_sfx.bind(_snd_door_open))
	tw.tween_property(_doors[0], "rotation:y", DOOR_OPEN_RAD, 0.26) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tw.tween_callback(_finish_exit)
	tw.tween_property(_doors[0], "rotation:y", 0.0, 0.3) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tw.tween_callback(_play_sfx.bind(_snd_door_close))
	tw.tween_callback(_release_door)


func _finish_exit() -> void:
	var p = _player
	_player = null
	# Door point: just OUTSIDE the actual collider width with a safe margin —
	# spawning the capsule inside the car box made the solver kick the car (flips).
	# Driver side (left) so the player steps out where the door panel swings.
	var door := Vector3(-(_box_half_x + 0.9), 1.2, 0.2)
	var t := global_transform.translated_local(door)
	if t.origin.y < 1.0:
		t.origin.y = 1.0   # never spawn the capsule underground when the car is tilted
	p.exit_car(self, t)
	_loop.stop()
	_sfx2.stream = _snd_stop
	_sfx2.play()


func _release_door() -> void:
	_door_busy = false
	_exiting = false


func _play_sfx(stream: AudioStream) -> void:
	_sfx.stream = stream
	_sfx.play()


func _start_engine() -> void:
	_sfx2.stream = _snd_start
	_sfx2.play()
	_loop.play()


## Cosmetic hinged doors on BOTH sides — the car meshes are single shells with
## no openable doors, so paint-matched panels swing on enter/exit instead.
func _spawn_door(paint_tex: Texture2D) -> void:
	if _doors.size() > 0:
		return
	var mat := StandardMaterial3D.new()
	mat.albedo_color = _avg_paint_color(paint_tex)
	mat.roughness = 0.55
	mat.metallic = 0.15
	for side_x in [-1.0, 1.0]:
		var pivot := Node3D.new()
		pivot.name = "DoorPivotL" if side_x < 0.0 else "DoorPivotR"
		$ModelRoot.add_child(pivot)
		pivot.position = Vector3(side_x * (_box_half_x + 0.02), 0.95, 0.58)
		var panel := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.05, 0.72, 0.92)
		panel.mesh = bm
		panel.position = Vector3(0, 0, -0.46)   # panel extends rearward from the hinge
		panel.material_override = mat
		pivot.add_child(panel)
		_doors.append(pivot)


## Average of the car's texture ≈ body paint color (skip dark glass / white graphics).
func _avg_paint_color(tex: Texture2D) -> Color:
	var fallback := Color(0.28, 0.28, 0.32)
	if tex == null:
		return fallback
	var img := tex.get_image()
	if img == null:
		return fallback
	img.decompress()
	img.convert(Image.FORMAT_RGBA8)
	var w := img.get_width()
	var h := img.get_height()
	if w == 0 or h == 0:
		return fallback
	var r := 0.0
	var g := 0.0
	var b := 0.0
	var n := 0
	for y in range(0, h, maxi(1, h / 24)):
		for x in range(0, w, maxi(1, w / 24)):
			var c := img.get_pixel(x, y)
			var val := maxf(c.r, maxf(c.g, c.b))
			if c.a > 0.5 and val > 0.15 and val < 0.95:
				r += c.r
				g += c.g
				b += c.b
				n += 1
	if n == 0:
		return fallback
	return Color(r / n, g / n, b / n)


## --- driving --------------------------------------------------------------
func _physics_process(delta: float) -> void:
	if _player == null:
		return

	var fwd_speed := linear_velocity.dot(global_transform.basis.z * FORWARD_SIGN)

	if _exiting:
		# Exit door animation is running: cut the throttle and let the car settle.
		brake = 6.0
		engine_force = 0.0
		steering = lerpf(steering, 0.0, minf(1.0, STEER_SPEED * 2.0 * delta))
	else:
		# Throttle / brake / reverse
		var fwd := Input.get_action_strength("move_forward")
		var back := Input.get_action_strength("move_back")
		if back > 0.0:
			if fwd_speed > 0.8:
				brake = BRAKE_FORCE
				engine_force = 0.0
			else:
				brake = 0.0
				engine_force = -REVERSE_FORCE
		elif fwd > 0.0:
			brake = 0.0
			engine_force = fwd * ENGINE_FORCE
		else:
			brake = 2.0              # gentle engine braking
			engine_force = 0.0

		# Space = handbrake (reuses the jump action while driving)
		if Input.is_action_pressed("jump"):
			brake = BRAKE_FORCE * 2.5

		# Steering: positive = left, reduced at speed
		var steer_target := Input.get_axis("move_right", "move_left") * MAX_STEER
		steer_target *= 1.0 / (1.0 + absf(fwd_speed) * 0.05)
		steering = lerpf(steering, steer_target, minf(1.0, STEER_SPEED * delta))

		# Horn
		if Input.is_action_just_pressed("horn"):
			_sfx.stream = _snd_horn
			_sfx.play()

	# Keep the (seated) player at the seat so the camera rig follows the car
	if is_instance_valid(_player):
		_player.global_position = global_transform.translated_local(SEAT_LOCAL).origin
		_player.set_drive_pose(global_rotation.y)

	# Engine loop pitch tracks speed
	_loop.pitch_scale = clampf(0.7 + absf(fwd_speed) / 20.0, 0.7, 2.4)
