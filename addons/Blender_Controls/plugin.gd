@tool
extends EditorPlugin

# ==================================================
# Blender-accurate G / R / S shortcuts for Godot 4
#
# MOVE   (G)
#   Unprojection-based: the mouse position is cast through the camera
#   onto the plane at the object's depth, giving true perspective-correct
#   world coordinates with zero edge distortion.
#
# ROTATE (R)
#   - R once  : view-spin. The angle is atan2(mouse - origin_screen)
#               minus atan2(mouse_start - origin_screen), so the object
#               literally rotates toward the cursor with the origin as pivot.
#   - R twice : trackball — camera-relative two-axis rotation,
#               driven by raw pixel delta (intentionally linear here).
#   - X/Y/Z   : world-axis lock, horizontal drag = angle.
#
# SCALE  (S)
#   Ratio of current mouse distance to initial mouse distance from the
#   projected origin — exactly Blender's model.
#
# NUMERIC INPUT
#   When an axis is locked (X/Y/Z), you can type a number instead of
#   using the mouse. The typed number replaces mouse input entirely.
#   - Move  + axis + number : move N units along that axis.
#   - Rotate + axis + number: rotate N degrees around that axis.
#   - Scale  + axis + number: scale to N along that axis.
#   - Move/Scale with NO axis lock: numbers are ignored.
#   - Rotate with NO axis lock (view-spin): numbers are supported,
#     typing a number rotates by N degrees around the view axis.
#   Press Backspace to delete last digit. Press Enter or LMB to confirm.
#   Negative values supported (type '-' as the first character).
#
# SNAP
#   Reads the editor's snap settings automatically.
#   When snap is enabled in the editor toolbar, transforms snap to the
#   configured grid/angle/scale increments.
#   - Move  : snaps to "Translate Snap" value (default 1 unit).
#   - Rotate: snaps to "Rotate Snap"    value (default 15 degrees).
#   - Scale : snaps to "Scale Snap"     value (default 0.1).
#
# PIVOT ROTATION  (R on a second object)
#   While rotating, press P to pick a pivot object from your selection.
#   If you have multiple nodes selected, the pivot cycles through them.
#   The object rotates *around* the pivot's world position.
#   Press P again to cycle, Escape resets to self-pivot.
#
# NAVIGATION
#   All shortcuts are suppressed while RMB is held (FPS nav mode).
#   Shortcuts only fire when the mouse is inside the 3-D viewport.
# ==================================================

var active_mode  := ""
var axis_lock    := ""
var rotate_taps  := 0   # 1 = view-spin, 2 = trackball

var selected_node : Node3D = null

var start_position := Vector3.ZERO
var start_rotation := Vector3.ZERO
var start_scale    := Vector3.ONE

# Accumulated pixel delta — used only by rotate (trackball) and scale.
var mouse_accum := Vector2.ZERO

# ── Saved at transform-start ──────────────────────
# World-space plane the object sits on (used by move unprojection).
var object_depth_plane : Plane

# Screen-space pixel position of the projected object origin.
var origin_screen := Vector2.ZERO

# Screen-space pixel position of the mouse when the transform began.
var mouse_start_screen := Vector2.ZERO

# World-space position the mouse was pointing at when move began.
var move_grab_world := Vector3.ZERO

var rmb_held := false

var undo_redo : EditorUndoRedoManager

# ── Numeric input ─────────────────────────────────
# Digits (and optional leading '-') typed during a transform.
var numeric_input := ""          # raw string being built
var numeric_active := false      # true once at least one digit (or '-') entered

# ── Snap ──────────────────────────────────────────
# Cached snap settings read from editor each frame.
var snap_translate := 1.0
var snap_rotate    := 15.0   # degrees
var snap_scale     := 0.1

# ── Pivot rotation ────────────────────────────────
# Index into the selection list used as pivot; -1 = use self (no pivot).
var pivot_index := -1
var pivot_world_pos := Vector3.ZERO

# All nodes in the current selection (cached at begin_transform).
var all_selected_nodes : Array[Node3D] = []


# ==================================================
# PLUGIN LIFECYCLE
# ==================================================

func _enter_tree() -> void:
	undo_redo = get_undo_redo()
	print("Blender Controls: enabled")


func _exit_tree() -> void:
	if is_transforming():
		cancel_transform()
	print("Blender Controls: disabled")


# ==================================================
# INPUT
# ==================================================

func _input(event: InputEvent) -> void:

	# ── RMB hold tracking (navigation guard) ────────
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			rmb_held = event.pressed
			if rmb_held and is_transforming():
				cancel_transform()
				get_viewport().set_input_as_handled()
				return

	if rmb_held:
		return

	# ── Key presses ─────────────────────────────────
	if event is InputEventKey and event.pressed and not event.echo:

		# ── Numeric input handling (takes priority when transforming) ──
		if is_transforming():
			var kc : int = event.keycode

			# Digits 0-9
			if kc >= KEY_0 and kc <= KEY_9:
				var digit := str(kc - KEY_0)
				# Ignore numeric input when no axis is locked AND mode is move or scale
				if axis_lock == "" and active_mode in ["move", "scale"]:
					get_viewport().set_input_as_handled()
					return
				numeric_input += digit
				numeric_active = true
				_update_numeric_display()
				update_transform()
				get_viewport().set_input_as_handled()
				return

			# Period (decimal point) — allow one decimal
			if kc == KEY_PERIOD:
				if axis_lock == "" and active_mode in ["move", "scale"]:
					get_viewport().set_input_as_handled()
					return
				if "." not in numeric_input:
					numeric_input += "."
					_update_numeric_display()
				get_viewport().set_input_as_handled()
				return

			# Minus sign (only at start)
			if kc == KEY_MINUS:
				if axis_lock == "" and active_mode in ["move", "scale"]:
					get_viewport().set_input_as_handled()
					return
				if numeric_input == "":
					numeric_input = "-"
					_update_numeric_display()
				get_viewport().set_input_as_handled()
				return

			# Backspace — remove last character
			if kc == KEY_BACKSPACE and numeric_active:
				if numeric_input.length() > 0:
					numeric_input = numeric_input.left(numeric_input.length() - 1)
				if numeric_input == "" or numeric_input == "-":
					numeric_active = false
					numeric_input  = ""
				_update_numeric_display()
				update_transform()
				get_viewport().set_input_as_handled()
				return

			# Enter / Numpad Enter — confirm
			if kc == KEY_ENTER or kc == KEY_KP_ENTER:
				confirm_transform()
				get_viewport().set_input_as_handled()
				return

		# ── Mode keys ──────────────────────────────────
		match event.keycode:

			KEY_G:
				if can_start_transform():
					begin_transform("move")
					get_viewport().set_input_as_handled()

			KEY_R:
				if is_transforming() and active_mode == "rotate" and axis_lock == "":
					rotate_taps = 2
					mouse_accum = Vector2.ZERO
					numeric_input  = ""
					numeric_active = false
					print("Blender Controls: trackball mode")
					get_viewport().set_input_as_handled()
				elif can_start_transform():
					begin_transform("rotate")
					get_viewport().set_input_as_handled()

			KEY_S:
				if can_start_transform():
					begin_transform("scale")
					get_viewport().set_input_as_handled()

			KEY_X:
				if is_transforming():
					_set_axis_lock("x")
					get_viewport().set_input_as_handled()

			KEY_Y:
				if is_transforming():
					_set_axis_lock("y")
					get_viewport().set_input_as_handled()

			KEY_Z:
				if is_transforming():
					_set_axis_lock("z")
					get_viewport().set_input_as_handled()

			KEY_P:
				# Cycle pivot object while rotating
				if is_transforming() and active_mode == "rotate":
					_cycle_pivot()
					get_viewport().set_input_as_handled()

			KEY_ESCAPE:
				if is_transforming():
					cancel_transform()
					get_viewport().set_input_as_handled()

	# ── Mouse motion ─────────────────────────────────
	if event is InputEventMouseMotion and is_transforming():
		mouse_accum += event.relative
		update_transform()
		get_viewport().set_input_as_handled()

	# ── Mouse buttons ────────────────────────────────
	if event is InputEventMouseButton and event.pressed and is_transforming():
		if event.button_index == MOUSE_BUTTON_LEFT:
			confirm_transform()
			get_viewport().set_input_as_handled()


# ==================================================
# AXIS LOCK HELPER (clears numeric when axis changes)
# ==================================================

func _set_axis_lock(axis: String) -> void:
	# Pressing the same axis again removes the lock
	if axis_lock == axis:
		axis_lock      = ""
		numeric_input  = ""
		numeric_active = false
	else:
		axis_lock      = axis
		numeric_input  = ""
		numeric_active = false
	_update_numeric_display()
	update_transform()


# ==================================================
# NUMERIC DISPLAY (prints to output for visibility)
# ==================================================

func _update_numeric_display() -> void:
	if numeric_active:
		print("Blender Controls: [", active_mode, "|", axis_lock.to_upper() if axis_lock != "" else "FREE", "] input = ", numeric_input)


# ==================================================
# SNAP HELPERS
# ==================================================

func _refresh_snap_settings() -> void:
	var settings := EditorInterface.get_editor_settings()
	# Godot 4 editor setting keys for snap
	if settings.has_setting("editors/3d/default_z_near"):
		pass  # settings object is valid

	# These are the canonical Godot 4 snap setting paths:
	var t = settings.get_setting("editors/3d/translate_snap_step") if settings.has_setting("editors/3d/translate_snap_step") else 1.0
	var r = settings.get_setting("editors/3d/rotate_snap_step")    if settings.has_setting("editors/3d/rotate_snap_step")    else 15.0
	var s = settings.get_setting("editors/3d/scale_snap_step")     if settings.has_setting("editors/3d/scale_snap_step")     else 10.0

	snap_translate = float(t)
	snap_rotate    = float(r)
	snap_scale     = float(s) * 0.01  # stored as percent in editor, convert to multiplier


func _is_snap_enabled() -> bool:
	# Snap is toggled by the magnet button; its state is in the editor settings.
	var settings := EditorInterface.get_editor_settings()
	if settings.has_setting("editors/3d/snap/use_snap"):
		return bool(settings.get_setting("editors/3d/snap/use_snap"))
	return false


func _snap_value(value: float, increment: float) -> float:
	if increment <= 0.0:
		return value
	return round(value / increment) * increment


# ==================================================
# VIEWPORT HOVER CHECK
# ==================================================

func is_mouse_over_3d_viewport() -> bool:
	var vp = get_editor_interface().get_editor_viewport_3d(0)
	if vp == null:
		return false
	var container = vp.get_parent()
	if not (container is Control):
		return false
	return container.get_global_rect().has_point(container.get_global_mouse_position())


# ==================================================
# STATE HELPERS
# ==================================================

func is_transforming() -> bool:
	return active_mode != ""


func can_start_transform() -> bool:
	if not is_mouse_over_3d_viewport():
		return false
	var nodes := get_editor_interface().get_selection().get_selected_nodes()
	if nodes.is_empty() or not (nodes[0] is Node3D):
		return false
	return true


# ==================================================
# PIVOT HELPERS
# ==================================================

func _cycle_pivot() -> void:
	if all_selected_nodes.size() <= 1:
		print("Blender Controls: only one node selected, no pivot to cycle")
		return

	pivot_index = (pivot_index + 1) % all_selected_nodes.size()

	# Skip self as the pivot (that's the default state)
	var primary_idx := all_selected_nodes.find(selected_node)
	if pivot_index == primary_idx:
		pivot_index = (pivot_index + 1) % all_selected_nodes.size()

	var pivot_node := all_selected_nodes[pivot_index]
	pivot_world_pos = pivot_node.global_position
	print("Blender Controls: pivot = ", pivot_node.name, " @ ", pivot_world_pos)
	update_transform()


func _get_pivot() -> Vector3:
	if pivot_index >= 0 and pivot_index < all_selected_nodes.size():
		return all_selected_nodes[pivot_index].global_position
	return selected_node.global_position


# ==================================================
# TRANSFORM START
# ==================================================

func begin_transform(mode: String) -> void:
	if is_transforming():
		cancel_transform()

	var nodes := get_editor_interface().get_selection().get_selected_nodes()
	if nodes.is_empty():
		return

	selected_node  = nodes[0]
	active_mode    = mode
	axis_lock      = ""
	rotate_taps    = 1
	mouse_accum    = Vector2.ZERO
	numeric_input  = ""
	numeric_active = false
	pivot_index    = -1
	pivot_world_pos = Vector3.ZERO

	# Cache all Node3D nodes in the selection for pivot cycling
	all_selected_nodes.clear()
	for n in nodes:
		if n is Node3D:
			all_selected_nodes.append(n)

	start_position = selected_node.position
	start_rotation = selected_node.rotation
	start_scale    = selected_node.scale

	_refresh_snap_settings()

	var camera := _get_editor_camera()

	# ── Project origin to screen ─────────────────────
	if camera != null:
		origin_screen = camera.unproject_position(selected_node.global_position)
	else:
		origin_screen = _get_viewport_size() * 0.5

	mouse_start_screen = _get_mouse_in_viewport()

	# ── Build the depth plane for move unprojection ──
	if camera != null:
		var cam_forward := -camera.global_basis.z
		object_depth_plane = Plane(cam_forward, selected_node.global_position)
		move_grab_world = _unproject_to_plane(camera, mouse_start_screen, object_depth_plane)
	else:
		object_depth_plane = Plane(Vector3.FORWARD, selected_node.global_position)
		move_grab_world    = selected_node.global_position

	print("Blender Controls: begin ", mode)


# ==================================================
# LIVE TRANSFORM UPDATE
# ==================================================

func update_transform() -> void:
	if selected_node == null:
		return

	var camera     := _get_editor_camera()
	var do_snap    := _is_snap_enabled()

	match active_mode:

		# ──────────────────────────────────────────────
		# MOVE  (G)
		# Axis-locked with numeric input:  position = start + N * axis
		# Axis-locked mouse:               project world delta onto axis
		# Free mouse:                      full world delta (no numeric)
		# ──────────────────────────────────────────────
		"move":
			if camera == null:
				return

			if axis_lock != "" and numeric_active:
				# ── Numeric axis move ──
				var n := _parse_numeric()
				if do_snap:
					n = _snap_value(n, snap_translate)
				var axis_vec := _world_axis_vec(axis_lock)
				selected_node.position = start_position + axis_vec * n

			else:
				# ── Mouse move ──
				var current_mouse := mouse_start_screen + mouse_accum
				var world_now     := _unproject_to_plane(camera, current_mouse, object_depth_plane)
				var world_delta   := world_now - move_grab_world

				if axis_lock == "":
					if do_snap:
						world_delta.x = _snap_value(world_delta.x, snap_translate)
						world_delta.y = _snap_value(world_delta.y, snap_translate)
						world_delta.z = _snap_value(world_delta.z, snap_translate)
					selected_node.position = start_position + world_delta
				else:
					var axis_vec  := _world_axis_vec(axis_lock)
					var projected := axis_vec * world_delta.dot(axis_vec)
					if do_snap:
						var dist := projected.dot(axis_vec)
						dist = _snap_value(dist, snap_translate)
						projected = axis_vec * dist
					selected_node.position = start_position + projected

		# ──────────────────────────────────────────────
		# ROTATE  (R / R-R)
		#
		# Numeric input:
		#   - With axis lock (X/Y/Z):   rotate N degrees around that world axis.
		#   - Without axis lock (view):  rotate N degrees around view axis.
		#   - Trackball mode:            numeric input ignored.
		#
		# Pivot:  when pivot_index >= 0 the object orbits around pivot_world_pos
		#         instead of its own origin.
		# ──────────────────────────────────────────────
		"rotate":
			var s        := _rotate_sensitivity()
			var pivot    := _get_pivot()
			var use_pivot := pivot_index >= 0

			if axis_lock != "":
				var angle_deg := 0.0
				if numeric_active:
					angle_deg = _parse_numeric()
				else:
					angle_deg = rad_to_deg(mouse_accum.x * s)

				if do_snap:
					angle_deg = _snap_value(angle_deg, snap_rotate)

				var angle_rad := deg_to_rad(angle_deg)
				var axis_vec  := _world_axis_vec(axis_lock)
				var rot       := start_rotation

				if use_pivot:
					_apply_rotation_around_pivot(axis_vec, angle_rad, pivot)
				else:
					match axis_lock:
						"x": rot.x = start_rotation.x + angle_rad
						"y": rot.y = start_rotation.y + angle_rad
						"z": rot.z = start_rotation.z + angle_rad
					selected_node.rotation = rot

			elif rotate_taps == 1 and camera != null:
				# ── View-spin ──
				var spin_angle := 0.0

				if numeric_active:
					spin_angle = deg_to_rad(_parse_numeric())
				else:
					var current_mouse := mouse_start_screen + mouse_accum
					var v_start  := mouse_start_screen - origin_screen
					var v_now    := current_mouse       - origin_screen
					var angle_start  := atan2(v_start.y, v_start.x)
					var angle_now    := atan2(v_now.y,   v_now.x)
					spin_angle = angle_now - angle_start

				if do_snap:
					spin_angle = deg_to_rad(_snap_value(rad_to_deg(spin_angle), snap_rotate))

				var cam_forward := -camera.global_basis.z

				if use_pivot:
					_apply_rotation_around_pivot(cam_forward.normalized(), spin_angle, pivot)
				else:
					var spin      := Quaternion(cam_forward.normalized(), spin_angle)
					var base_quat := Quaternion.from_euler(start_rotation)
					selected_node.rotation = (spin * base_quat).get_euler()

			elif rotate_taps == 2 and camera != null:
				# ── Trackball (no numeric input, no pivot in trackball) ──
				var cam_right := camera.global_basis.x
				var cam_up    := camera.global_basis.y
				var q_h       := Quaternion(cam_up.normalized(),    mouse_accum.x * s)
				var q_v       := Quaternion(cam_right.normalized(), mouse_accum.y * s)
				var base_quat := Quaternion.from_euler(start_rotation)
				var euler     := (q_h * q_v * base_quat).get_euler()

				if do_snap:
					euler.x = deg_to_rad(_snap_value(rad_to_deg(euler.x), snap_rotate))
					euler.y = deg_to_rad(_snap_value(rad_to_deg(euler.y), snap_rotate))
					euler.z = deg_to_rad(_snap_value(rad_to_deg(euler.z), snap_rotate))

				selected_node.rotation = euler

			else:
				var rot := start_rotation
				rot.y = start_rotation.y + mouse_accum.x * s
				selected_node.rotation = rot

		# ──────────────────────────────────────────────
		# SCALE  (S)
		# Numeric input with axis lock: scale = start_scale.axis * N
		# Numeric input free:           ignored (same as move)
		# Mouse: ratio of distances from screen origin
		# ──────────────────────────────────────────────
		"scale":
			var factor := 1.0

			if axis_lock != "" and numeric_active:
				# ── Numeric scale ──
				factor = _parse_numeric()
				if do_snap:
					factor = _snap_value(factor, snap_scale)
				var scl := start_scale
				match axis_lock:
					"x": scl.x = start_scale.x * factor
					"y": scl.y = start_scale.y * factor
					"z": scl.z = start_scale.z * factor
				_clamp_scale(scl, factor)
				selected_node.scale = scl

			else:
				# ── Mouse scale ──
				var current_mouse := mouse_start_screen + mouse_accum
				var v_start  := mouse_start_screen - origin_screen
				var v_now    := current_mouse       - origin_screen

				var initial_dist := v_start.length()
				var current_dist := v_now.length()
				if initial_dist < 1.0:
					initial_dist = 1.0

				factor = current_dist / initial_dist
				if v_start.dot(v_now) < 0.0:
					factor = -factor

				if do_snap:
					factor = _snap_value(factor, snap_scale)

				var scl := start_scale
				match axis_lock:
					"x":
						scl.x = start_scale.x * factor
					"y":
						scl.y = start_scale.y * factor
					"z":
						scl.z = start_scale.z * factor
					_:
						scl = start_scale * factor

				_clamp_scale(scl, factor)
				selected_node.scale = scl


# ==================================================
# PIVOT ROTATION HELPER
# Rotates selected_node around an arbitrary world-space pivot point.
# The object's own rotation is also updated to match.
# ==================================================

func _apply_rotation_around_pivot(axis: Vector3, angle: float, pivot: Vector3) -> void:
	var rot_quat  := Quaternion(axis.normalized(), angle)

	# Rotate the position offset around the pivot
	var offset := start_position - pivot
	var rotated_offset := rot_quat * offset
	selected_node.global_position = pivot + rotated_offset

	# Also apply the rotation to the node's own orientation
	var base_quat := Quaternion.from_euler(start_rotation)
	selected_node.rotation = (rot_quat * base_quat).get_euler()


# ==================================================
# SCALE CLAMP HELPER
# ==================================================

func _clamp_scale(scl: Vector3, factor: float) -> void:
	var sign_f := signf(factor) if factor != 0.0 else 1.0
	if abs(scl.x) < 0.001: scl.x = 0.001 * sign_f
	if abs(scl.y) < 0.001: scl.y = 0.001 * sign_f
	if abs(scl.z) < 0.001: scl.z = 0.001 * sign_f


# ==================================================
# NUMERIC PARSE
# ==================================================

func _parse_numeric() -> float:
	if numeric_input == "" or numeric_input == "-":
		return 0.0
	return float(numeric_input)


# ==================================================
# CONFIRM
# ==================================================

func confirm_transform() -> void:
	if selected_node == null:
		return

	undo_redo.create_action("Blender Transform: " + active_mode)
	undo_redo.add_do_property(selected_node,   "position", selected_node.position)
	undo_redo.add_do_property(selected_node,   "rotation", selected_node.rotation)
	undo_redo.add_do_property(selected_node,   "scale",    selected_node.scale)
	undo_redo.add_undo_property(selected_node, "position", start_position)
	undo_redo.add_undo_property(selected_node, "rotation", start_rotation)
	undo_redo.add_undo_property(selected_node, "scale",    start_scale)
	undo_redo.commit_action()

	print("Blender Controls: confirmed")
	reset_transform_state()


# ==================================================
# CANCEL
# ==================================================

func cancel_transform() -> void:
	if selected_node == null:
		return

	selected_node.position = start_position
	selected_node.rotation = start_rotation
	selected_node.scale    = start_scale

	print("Blender Controls: cancelled")
	reset_transform_state()


# ==================================================
# RESET
# ==================================================

func reset_transform_state() -> void:
	active_mode        = ""
	axis_lock          = ""
	rotate_taps        = 0
	mouse_accum        = Vector2.ZERO
	selected_node      = null
	numeric_input      = ""
	numeric_active     = false
	pivot_index        = -1
	pivot_world_pos    = Vector3.ZERO
	all_selected_nodes.clear()


# ==================================================
# SENSITIVITY
# ==================================================

func _rotate_sensitivity() -> float:
	# Full viewport width = 2π.
	return (2.0 * PI) / max(_get_viewport_size().x, 1.0)


# ==================================================
# INTERNAL HELPERS
# ==================================================

func _get_editor_camera() -> Camera3D:
	var vp = get_editor_interface().get_editor_viewport_3d(0)
	if vp == null:
		return null
	return vp.get_camera_3d()


func _get_viewport_size() -> Vector2:
	var vp = get_editor_interface().get_editor_viewport_3d(0)
	if vp == null:
		return Vector2(1280, 720)
	return Vector2(vp.size)


func _get_mouse_in_viewport() -> Vector2:
	var vp = get_editor_interface().get_editor_viewport_3d(0)
	if vp == null:
		return Vector2.ZERO
	var container = vp.get_parent()
	if not (container is Control):
		return Vector2.ZERO
	return container.get_local_mouse_position()


func _unproject_to_plane(camera: Camera3D, screen_px: Vector2, plane: Plane) -> Vector3:
	var ray_origin    := camera.project_ray_origin(screen_px)
	var ray_direction := camera.project_ray_normal(screen_px)

	var hit := plane.intersects_ray(ray_origin, ray_direction)
	if hit != null:
		return hit
	var dist := camera.global_position.distance_to(plane.get_center())
	return ray_origin + ray_direction * dist


func _world_axis_vec(axis: String) -> Vector3:
	match axis:
		"x": return Vector3.RIGHT
		"y": return Vector3.UP
		"z": return Vector3.BACK
	return Vector3.ZERO
