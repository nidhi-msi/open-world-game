extends CharacterBody3D
## Third-person player controller.
## Rig: Player (CharacterBody3D, never rotated)
##      > Model (Node3D, rotates to face movement)
##        > Body (UAL1_Standard.glb mannequin + 43 animations)
##      > CameraRig (yaw follows mouse X)
##        > SpringArm3D (pitch follows mouse Y, collision-aware)
##          > Camera3D

const MOUSE_SENS := 0.0025
const WALK_SPEED := 2.6
const JOG_SPEED := 4.6
const SPRINT_SPEED := 7.2
const ACCEL := 10.0
const AIR_ACCEL := 3.0
const JUMP_VELOCITY := 4.9
const GRAVITY := 15.0

## The default glTF import axis-maps the mannequin facing +Z in Godot.
## If the character appears to walk backwards, change this to PI.
const MODEL_FORWARD_OFFSET := 0.0

# Animation names as imported by Godot 4.3 (the glTF importer strips _Loop etc.):
const ANIM_IDLE := "Idle"
const ANIM_WALK := "Walk"
const ANIM_JOG := "Jog_Fwd"
const ANIM_SPRINT := "Sprint"
const ANIM_JUMP := "Jump"
const ANIM_DRIVE := "Driving"

@onready var model: Node3D = $Model
@onready var rig: Node3D = $CameraRig
@onready var arm: SpringArm3D = $CameraRig/SpringArm3D
@onready var camera: Camera3D = $CameraRig/SpringArm3D/Camera3D

var _ap: AnimationPlayer
var _current_anim := ""

var driving := false
var _driving_car = null


func _ready() -> void:
	# Find the AnimationPlayer inside the instantiated .glb no matter its node name.
	var found := find_children("*", "AnimationPlayer", true, false)
	if found.size() > 0:
		_ap = found[0]
	else:
		push_warning("UAL1 AnimationPlayer not found under Player/Model/Body.")
	# Keep the camera spring arm from colliding with our own capsule body.
	arm.add_excluded_object(get_rid())
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		rig.rotation.y -= event.relative.x * MOUSE_SENS
		# Clamp pitch: look down max ~52 deg, up ~34 deg.
		arm.rotation.x = clampf(arm.rotation.x - event.relative.y * MOUSE_SENS, -0.91, 0.60)
		# Sign check: negative relative.y = mouse up = arm pitch grows positive = camera looks up (non-inverted, FPS-style).
	elif event.is_action_pressed("ui_cancel"):
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		else:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif event.is_action_pressed("interact"):
		if driving:
			if _driving_car != null and is_instance_valid(_driving_car):
				_driving_car.exit_player()
		else:
			var best = null
			var best_d := 4.0
			for c in get_tree().get_nodes_in_group("cars"):
				var d: float = global_position.distance_to((c as Node3D).global_position)
				if d < best_d:
					best_d = d
					best = c
			if best != null:
				best.enter_player(self)


func _physics_process(delta: float) -> void:
	if driving:
		# Car.gd drives our position and pose; engine audio lives on the car.
		velocity = Vector3.ZERO
		_update_animation()
		return

	# Gravity
	if not is_on_floor():
		velocity.y -= GRAVITY * delta

	# Jump
	if is_on_floor() and Input.is_action_just_pressed("jump"):
		velocity.y = JUMP_VELOCITY

	# Camera-relative move direction
	var input := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var dir := rig.global_transform.basis * Vector3(input.x, 0.0, input.y)
	dir.y = 0.0
	dir = dir.normalized() if dir.length() > 0.01 else Vector3.ZERO

	# Sprint / walk speeds
	var target_speed := JOG_SPEED
	if Input.is_action_pressed("sprint"):
		target_speed = SPRINT_SPEED
	elif dir != Vector3.ZERO and Input.is_action_pressed("move_forward") == false \
			and Input.is_action_pressed("move_back") == false:
		target_speed = WALK_SPEED  # strafing only = walk pace

	# Frame-rate-independent acceleration (exponential smoothing — equally
	# smooth at 60 Hz and 144+ Hz; the old step formula juddered on high-refresh displays)
	var target_xz := dir * target_speed
	var accel := ACCEL if is_on_floor() else AIR_ACCEL
	var blend := 1.0 - exp(-accel * delta)
	velocity.x = lerpf(velocity.x, target_xz.x, blend)
	velocity.z = lerpf(velocity.z, target_xz.z, blend)

	move_and_slide()

	_update_facing(delta)
	_update_animation()


func _update_facing(delta: float) -> void:
	var horiz := Vector2(velocity.x, velocity.z)
	if horiz.length() > 0.4:
		var target_yaw := atan2(horiz.x, horiz.y) + MODEL_FORWARD_OFFSET
		model.rotation.y = lerp_angle(model.rotation.y, target_yaw, minf(1.0, 12.0 * delta))


func _update_animation() -> void:
	if _ap == null:
		return
	if driving:
		if _current_anim != ANIM_DRIVE:
			_current_anim = ANIM_DRIVE
			_ap.play(ANIM_DRIVE, 0.3)
		_ap.speed_scale = 1.0
		return
	var horiz := Vector2(velocity.x, velocity.z).length()
	var next: String
	var speed_scale := 1.0
	if not is_on_floor():
		next = ANIM_JUMP
	elif horiz < 0.4:
		next = ANIM_IDLE
	elif horiz < JOG_SPEED + 0.3:
		next = ANIM_JOG
		speed_scale = clampf(horiz / JOG_SPEED, 0.75, 1.15)
	else:
		next = ANIM_SPRINT
		speed_scale = clampf(horiz / SPRINT_SPEED, 0.9, 1.1)

	if Input.is_action_pressed("sprint") and horiz < 3.0 and is_on_floor() and horiz > 0.4:
		next = ANIM_WALK  # short bursts read better as walk when starting to sprint
		speed_scale = 1.0

	if next != _current_anim:
		_current_anim = next
		_ap.play(next, 0.25)
	_ap.speed_scale = speed_scale if next != ANIM_IDLE else 1.0


## --- vehicle integration (called by car.gd) -------------------------------
func enter_car(car) -> void:
	driving = true
	_driving_car = car
	velocity = Vector3.ZERO
	collision_layer = 0
	collision_mask = 0
	# Driver stays VISIBLE inside (windows are transparent glass now).
	set_camera_exclusion(car.get_rid(), true)


func exit_car(car, t: Transform3D) -> void:
	driving = false
	_driving_car = null
	collision_layer = 1
	collision_mask = 1
	global_transform = t
	velocity = Vector3.ZERO
	model.rotation.y = 0.0
	model.position.y = 0.0
	if has_method("reset_physics_interpolation"):
		reset_physics_interpolation()  # 4.4+: no one-frame smear on the door teleport
	set_camera_exclusion(car.get_rid(), false)


## While seated: face the same way the car faces, sunk slightly into the seat
## so the head stays under the roofline even on the lower car bodies.
func set_drive_pose(car_yaw: float) -> void:
	model.rotation.y = car_yaw + (PI - MODEL_FORWARD_OFFSET)
	model.position.y = -0.12


## Let the camera arm ignore a specific body (the car we are sitting in).
func set_camera_exclusion(rid: RID, add: bool) -> void:
	if add:
		arm.add_excluded_object(rid)
	else:
		arm.remove_excluded_object(rid)
