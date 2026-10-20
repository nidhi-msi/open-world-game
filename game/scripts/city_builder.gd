extends Node3D
## Procedural starter world (Phase 2).
##
## CITY (3x3 logic grid, plus-shaped roads):
##   - Center cell: Street_4WayIntersection (24.666 x 24.666 m) at origin
##   - Grid arms (N/S/E/W, 1 cell + 1 outer ring cell): Street_4Lane (6 m wide, 18 m long)
##   - Corner cells (4): 18 x 18 m sidewalk plazas (36 tiles each) with one prefab building
##   - Grass verges between roads and plazas; trees + planter pots as decoration
## VILLAGE: medieval house (wall/door/window ring + pitched roof + chimney),
##   garden fences, wagon, crates, trees, lamps, south of the city by the road.
##
## Every spawned piece gets concave (trimesh) static collision, so nothing
## falls through and curbs/steps are physically consistent.

# ------------------------------------------------------------------ assets
# City kit (glTF + .bin + textures live in the same folder)
const P_STREET := "res://Exports/glTF (Godot)/Street_4Lane.gltf"
const P_CROSS := "res://Exports/glTF (Godot)/Street_4WayIntersection.gltf"
const P_TILE := "res://Exports/glTF (Godot)/Sidewalk_NoCurb_3m.gltf"
const P_PLANTER := "res://Exports/glTF (Godot)/Sidewalk_Planter.gltf"
const P_BOLLARD := "res://Exports/glTF (Godot)/Prop_Bollard.gltf"
const P_BLDG_S := "res://Exports/glTF (Godot)/Building_Small_1.gltf"
const P_BLDG_M := "res://Exports/glTF (Godot)/Building_Medium_2_001.gltf"
const P_BLDG_L := "res://Exports/glTF (Godot)/Building_Large_2.gltf"

# PLUS pack (glb, self-textured / embedded textures)
const P_LAMP := "res://PLUS/gltf/lamp_1.glb"
const P_TREE := "res://PLUS/gltf/tree_1_a.glb"

# Medieval Village MegaKit
const V := "res://Medieval Village MegaKit[Standard]/glTF/"
const P_WALL := V + "Wall_Plaster_Straight.gltf"
const P_WALL_DOOR := V + "Wall_Plaster_Door_Flat.gltf"
const P_WALL_WINDOW := V + "Wall_Plaster_Window_Wide_Round.gltf"
const P_CORNER := V + "Corner_Exterior_Brick.gltf"
const P_FLOOR := V + "Floor_UnevenBrick.gltf"
const P_ROOF := V + "Roof_RoundTiles_6x6.gltf"
const P_CHIMNEY := V + "Prop_Chimney.gltf"
const P_WAGON := V + "Prop_Wagon.gltf"
const P_FENCE := V + "Prop_WoodenFence_Single.gltf"
const P_CRATE := V + "Prop_Crate.gltf"

# ------------------------------------------------- measured layout constants
const ARM_CTR := 21.333        # intersection center -> arm cell center (12.333 + 9)
const ARM_LEN := 18.0          # straight road tile length
const PLAZA_R := 21.333        # plaza centers (diagonal quadrants)
const HOUSE_YAW := -90.0       # village house door faces -x (toward the road)
const HOUSE_POS := Vector3(18, 0, 59)

var _cache: Dictionary = {}    # path -> PackedScene
var _shape_cache: Dictionary = {}  # mesh -> ConcavePolygonShape3D


func _ready() -> void:
	# Grass plane under everything, top at y=-0.02 (just below the road tiles' base -0.15)
	_build_ground()
	_build_city()
	_build_village()
	_build_border_walls()


# ---------------------------------------------------------------- helpers
func _instantiate(path: String) -> Node3D:
	if not _cache.has(path):
		var ps: PackedScene = load(path)
		if ps == null:
			push_error("Missing asset: " + path)
			return null
		_cache[path] = ps
	var ins: Node3D = _cache[path].instantiate()
	if ins == null:
		push_error("Instantiate failed: " + path)
		return null
	return ins


## Walks the hierarchy accumulating local transforms and unifying mesh AABBs.
## Returns [min: Vector3, max: Vector3] in root's local space (root excluded).
func _measure(root: Node3D) -> Array:
	var box := []
	_walk_meshes(root, Transform3D(), box)
	if box.is_empty():
		box = [Vector3.ZERO, Vector3.ZERO]
	return box


func _walk_meshes(node: Node, xf: Transform3D, box: Array) -> void:
	if node is Node3D:
		xf = xf * (node as Node3D).transform
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.mesh != null and mi.visible:
			var a: AABB = mi.mesh.get_aabb()
			# Transform the 8 corners (fully compatible with all Godot 4.x versions)
			var lo := Vector3(INF, INF, INF)
			var hi := Vector3(-INF, -INF, -INF)
			for i in 8:
				var corner := Vector3(
					(a.position.x if i & 1 != 0 else a.end.x),
					(a.position.y if i & 2 != 0 else a.end.y),
					(a.position.z if i & 4 != 0 else a.end.z)
				)
				var p := xf * corner
				lo = lo.min(p)
				hi = hi.max(p)
			if box.is_empty():
				box.append(lo)
				box.append(hi)
			else:
				box[0] = box[0].min(lo)
				box[1] = box[1].max(hi)
	for c in node.get_children():
		_walk_meshes(c, xf, box)


## Adds a static trimesh (concave) collider under every MeshInstance3D.
func _static_colliders(root: Node) -> void:
	var stack: Array = [root]
	while not stack.is_empty():
		var n = stack.pop_back()
		if n is MeshInstance3D:
			var mi := n as MeshInstance3D
			if mi.mesh != null:
				var shape: ConcavePolygonShape3D
				if _shape_cache.has(mi.mesh):
					shape = _shape_cache[mi.mesh]
				else:
					shape = mi.mesh.create_trimesh_shape()
					if shape == null:
						push_warning("No trimesh shape for mesh in %s" % root.name)
					_shape_cache[mi.mesh] = shape
				if shape != null:
					var cs := CollisionShape3D.new()
					cs.shape = shape
					var body := StaticBody3D.new()
					body.name = "StaticCol"
					body.add_child(cs)
					mi.add_child(body)
		for c in n.get_children():
			stack.append(c)


## Spawns a kit piece so its visual center lands exactly on `pos`
## (x,z centered, mesh bottom sitting on y=0), then gives it collision.
func _spawn(path: String, pos: Vector3, yaw_deg := 0.0, parent: Node = null) -> Node3D:
	if parent == null:
		parent = self
	var inst := _instantiate(path)
	if inst == null:
		return null
	var box := _measure(inst)
	var lo: Vector3 = box[0]
	var hi: Vector3 = box[1]
	var c: Vector3 = (lo + hi) * 0.5
	inst.position = Vector3(-c.x, -lo.y, -c.z)
	_static_colliders(inst)

	var wrap := Node3D.new()
	parent.add_child(wrap)
	wrap.add_child(inst)
	wrap.position = pos
	wrap.rotation.y = deg_to_rad(yaw_deg)
	return wrap


## Degree yaw for a lamp/prop at `from_pos` whose +X arm should face `target`.
func _yaw_arm_to(from_pos: Vector3, target: Vector3) -> float:
	var t := (target - from_pos)
	return rad_to_deg(atan2(t.x, t.z)) - 90.0


# ------------------------------------------------------------------- city
func _build_city() -> void:
	# Roads: intersection center + 4 arms x 2 tiles (plus shape through the map)
	_spawn(P_CROSS, Vector3.ZERO)
	for s in [1.0, -1.0]:
		_spawn(P_STREET, Vector3(s * ARM_CTR, 0, 0), 90.0)       # East / West arm
		_spawn(P_STREET, Vector3(s * (ARM_CTR + ARM_LEN), 0, 0), 90.0)
		_spawn(P_STREET, Vector3(0, 0, s * ARM_CTR), 0.0)          # North / South arm
		_spawn(P_STREET, Vector3(0, 0, s * (ARM_CTR + ARM_LEN)), 0.0)

	# Planter pots on the intersection's four sidewalk corners
	for sx in [1.0, -1.0]:
		for sz in [1.0, -1.0]:
			_spawn(P_PLANTER, Vector3(sx * 7.8, 0, sz * 7.8))

	# Four 18 x 18 plazas + buildings + furniture
	for sx in [1.0, -1.0]:
		for sz in [1.0, -1.0]:
			var base := Vector3(sx * PLAZA_R, 0, sz * PLAZA_R)
			# 36 flat sidewalk tiles (3 m), spanning +/- 9 m around the plaza center
			for a in 6:
				for b in 6:
					var t := base + Vector3(sx * (a - 2.5) * 3.0, 0, sz * (b - 2.5) * 3.0)
					_spawn(P_TILE, t)
			# ONE prefab building per plaza
			if sx == 1.0 and sz == -1.0:
				_spawn(P_BLDG_S, base)                                # NE: small
			elif sx == -1.0 and sz == -1.0:
				_spawn(P_BLDG_M, base)                                # NW: medium
			elif sx == -1.0 and sz == 1.0:
				_spawn(P_BLDG_S, base, 180.0)                         # SW: small, turned
			else:
				_spawn(P_BLDG_L, base)                                # SE: large (slight overhang ok)
			# Bollards guarding the plaza corner nearest the intersection
			_spawn(P_BOLLARD, base + Vector3(sx * -7.9, 0, sz * -7.9))
			_spawn(P_BOLLARD, base + Vector3(sx * -5.4, 0, sz * -7.9))
			# Street lamp lighting the intersection (arm + facing the center)
			var lp := base + Vector3(sx * -7.5, 0, sz * -7.5)
			_spawn(P_LAMP, lp, _yaw_arm_to(lp, Vector3.ZERO))

	# Grass-verge trees along the road sides (2 on each strip side of every arm)
	for s in [1.0, -1.0]:
		for sx in [1.0, -1.0]:
			_spawn(P_TREE, Vector3(sx * 7.7, 0, s * 20.0))
			_spawn(P_TREE, Vector3(sx * 7.7, 0, s * 26.0))
			_spawn(P_TREE, Vector3(sx * 21.0, 0, s * 7.7))
			_spawn(P_TREE, Vector3(sx * 28.0, 0, s * 7.7))


# ---------------------------------------------------------------- village
func _build_village() -> void:
	var house := Node3D.new()
	house.name = "VillageHouse"
	add_child(house)
	house.position = HOUSE_POS
	house.rotation.y = deg_to_rad(HOUSE_YAW)

	# Floor 3x3 tiles (6 x 6 m)
	for ix in [-1, 0, 1]:
		for iz in [-1, 0, 1]:
			_spawn(P_FLOOR, Vector3(ix * 2.0, 0, iz * 2.0), 0.0, house)

	# Wall ring: N (straight), E (straight/window), S (window/door/window), W (straight)
	for x in [-2.0, 0.0, 2.0]:
		_spawn(P_WALL, Vector3(x, 0, -3.0), 180.0, house)          # back, faces -z
	for z in [-2.0, 2.0]:
		_spawn(P_WALL, Vector3(3.0, 0, z), 90.0, house)            # east side ends
		_spawn(P_WALL, Vector3(-3.0, 0, z), -90.0, house)          # west side ends
	_spawn(P_WALL_WINDOW, Vector3(3.0, 0, 0.0), 90.0, house)      # east center window
	_spawn(P_WALL_WINDOW, Vector3(-3.0, 0, 0.0), -90.0, house)   # west center window
	_spawn(P_WALL_WINDOW, Vector3(-2.0, 0, 3.0), 0.0, house)     # front window left
	_spawn(P_WALL_WINDOW, Vector3(2.0, 0, 3.0), 0.0, house)      # front window right
	_spawn(P_WALL_DOOR, Vector3(0.0, 0, 3.0), 0.0, house)        # front door (faces +z local)

	# Exterior corner pillars at the four corners (face diagonally outward)
	_spawn(P_CORNER, Vector3(3.0, 0, -3.0), 135.0, house)
	_spawn(P_CORNER, Vector3(3.0, 0, 3.0), 45.0, house)
	_spawn(P_CORNER, Vector3(-3.0, 0, 3.0), -45.0, house)
	_spawn(P_CORNER, Vector3(-3.0, 0, -3.0), -135.0, house)

	# Pitched roof on top of the 3.12 m walls (eaves sit on the wall tops)
	_spawn(P_ROOF, Vector3(0, 3.9, 0), 0.0, house)
	# Chimney poking through the roof near the ridge
	_spawn(P_CHIMNEY, Vector3(0.7, 5.2, 0.3), 0.0, house)

	# Garden props (world coordinates)
	_spawn(P_WAGON, Vector3(24.5, 0, 62.5), 15.0)
	_spawn(P_CRATE, Vector3(14.6, 0, 52.6))
	_spawn(P_CRATE, Vector3(15.7, 0, 51.7))
	for fx in [23.0, 25.0, 27.0]:
		_spawn(P_FENCE, Vector3(fx, 0, 55.0))
	for fx in [20.0, 22.0, 24.0, 26.0]:
		_spawn(P_FENCE, Vector3(fx, 0, 47.0))

	# Village greenery
	_spawn(P_TREE, Vector3(24, 0, 51.5))
	_spawn(P_TREE, Vector3(26.5, 0, 60.5))
	_spawn(P_TREE, Vector3(11, 0, 64))
	_spawn(P_TREE, Vector3(8, 0, 50))
	_spawn(P_LAMP, Vector3(6.5, 0, 57), 180.0)
	_spawn(P_LAMP, Vector3(22.5, 0, 58.5), 180.0)


# ------------------------------------------------------------------ ground
## Big grass plane under the whole map + its shared static ground collision.
## Plane top / box top sit at y = -0.02, just under the road tiles (base -0.15),
## so stepping off a road/plaza onto the grass is a tiny 13 cm drop.
func _build_ground() -> void:
	var mi := MeshInstance3D.new()
	mi.name = "Ground"
	var pm := PlaneMesh.new()
	pm.size = Vector2(130, 200)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.21, 0.28, 0.13)
	mat.roughness = 1.0
	pm.material = mat
	mi.mesh = pm
	mi.position = Vector3(0, -0.16, 20)
	add_child(mi)

	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(130, 0.6, 200)
	cs.shape = bs
	var sb := StaticBody3D.new()
	sb.name = "GroundCol"
	sb.add_child(cs)
	sb.position = Vector3(0, -0.46, 20)
	add_child(sb)


## Invisible walls so the player cannot walk off the map edge yet.
func _build_border_walls() -> void:
	var defs := [
		[Vector3(0, 2.5, -57), Vector3(124, 5, 1)],     # north
		[Vector3(0, 2.5, 96), Vector3(124, 5, 1)],      # south (behind the village)
		[Vector3(-60, 2.5, 19.5), Vector3(1, 5, 154)],  # west
		[Vector3(60, 2.5, 19.5), Vector3(1, 5, 154)],   # east
	]
	for d in defs:
		var cs := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		bs.size = d[1]
		cs.shape = bs
		var sb := StaticBody3D.new()
		sb.name = "BorderWall"
		sb.add_child(cs)
		sb.position = d[0]
		add_child(sb)
