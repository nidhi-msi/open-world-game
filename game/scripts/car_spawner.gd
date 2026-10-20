extends Node3D
## Spawns the starter fleet of drivable cars around the city.
## Cars sit on the roads (road top = y 0); spawn at y 1.0 so suspension settles.

# [car obj, livery png (null = the obj's default MTL texture), position, yaw deg]
const FLEET := [
	["res://Car 01/Car.obj", null, Vector3(-8, 1.0, 0), -90.0],        # west arm, facing east
	["res://Car 02/Car2.obj", null, Vector3(8, 1.0, 0), 90.0],        # east arm, facing west
	["res://Car 05/Car5_Police.obj", null, Vector3(0, 1.0, -14), 180.0],   # north arm
	["res://Car 05/Car5_Taxi.obj", null, Vector3(0, 1.0, 14), 0.0],   # south arm
	["res://Car 03/Car3.obj", null, Vector3(0, 1.0, -40), 180.0],     # outer north segment
	["res://Car 04/Car4.obj", "res://Car 04/car4_grey.png", Vector3(40, 1.0, 0), -90.0],
	["res://Car 07/Car7.obj", null, Vector3(0, 1.0, 40), 0.0],        # near the village
	["res://Car 08/Car8.obj", null, Vector3(-40, 1.0, 0), 90.0],      # outer west segment
]

var _car_scene: PackedScene


func _ready() -> void:
	_car_scene = load("res://game/scenes/car.tscn")
	for def in FLEET:
		_spawn_car(def[0], def[1], def[2], def[3])


func _spawn_car(obj_path: String, livery_path, pos: Vector3, yaw_deg: float) -> void:
	var car = _car_scene.instantiate()
	add_child(car)
	car.position = pos
	car.rotation.y = deg_to_rad(yaw_deg)

	var res = load(obj_path)
	var mesh: Mesh = null
	if res is Mesh:
		mesh = res
	elif res is PackedScene:
		# Future-proof: if a Godot version imports obj as a scene, dig out its first mesh.
		var inst = (res as PackedScene).instantiate()
		var mis = inst.find_children("*", "MeshInstance3D", true, false)
		if mis.size() > 0:
			mesh = (mis[0] as MeshInstance3D).mesh
		inst.free()

	var livery: Texture2D = null
	if livery_path != null and ResourceLoader.exists(livery_path):
		livery = load(livery_path)

	car.set_model(mesh, livery)
