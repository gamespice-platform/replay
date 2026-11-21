class_name GSKillViewPlayer
extends Node

## Client side of the kill-cam: plays a killer-view clip through a [GSKillcam], slowed at the kill,
## and tells the game where to put its camera and crosshair. Draws no camera; the game does.

const CHANNEL := "replay.killview"

## Place the replay camera: transform, fov (degrees), cursor in 0..1 screen space, whether to draw it.
signal view(transform: Transform3D, fov: float, cursor: Vector2, has_cursor: bool)

## The replayed instant, seconds from the kill (negative before it), emitted just before [signal view]:
## the clip holds only the killer's eye, so the game poses the bodies it drew itself at this instant.
signal moment(seconds_from_kill: float)

## The killer's game-defined state at the replayed instant (see [constant GSKillViewRing.AUX]), just before [signal view].
signal state(aux: PackedFloat32Array)

## Over; [param skipped] when the victim (or a short clip) ended it early. The respawn flow resumes here.
signal finished(skipped: bool)

## The victim skipped: respawn now.
signal respawn_requested

var rules: GSKillViewRules = null

## Called on a skip, in addition to [signal respawn_requested]: the game's respawn request.
var respawn_fn: Callable = Callable()

## Advance in [method Node._process]; off for a test that calls [method advance].
var auto_process: bool = true

var killcam: GSKillcam = null


func _init(p_rules: GSKillViewRules = null) -> void:
	rules = p_rules if p_rules != null else GSKillViewRules.new()


func is_active() -> bool:
	return killcam != null and killcam.is_active()


## Starts the replay of [param clip]. Fails with CODE_STATE when off or running, CODE_PARSE for a bad clip.
func play_clip(clip: Dictionary, info: Dictionary = {}) -> GSResult:
	if not rules.enabled:
		return GSResult.fail(GSError.CODE_STATE, "The kill view is off.")
	var made := GSKillViewClip.to_buffer(clip)
	if not made.ok:
		return made.wrap("The kill view clip is unusable.")
	if killcam == null:
		killcam = GSKillcam.new()
		killcam.frame_drawn.connect(_on_frame)
		killcam.finished.connect(_on_finished)
		add_child(killcam)
	killcam.auto_process = auto_process
	killcam.wait_for_frames = false
	killcam.max_seconds = rules.seconds
	killcam.pre_seconds = rules.lead_seconds
	killcam.post_seconds = rules.post_seconds
	killcam.slow_scale = rules.slowmo
	killcam.skip_allowed = rules.skip_allowed
	killcam.skip_actions = PackedStringArray([rules.skip_action])
	killcam.skip_grace = rules.skip_grace
	var shown := info.duplicate()
	shown["title"] = shown.get("title", "KILL VIEW")
	if not rules.skip_allowed:
		shown["hint"] = ""
	var buffer: GSKillcamBuffer = made.value
	return killcam.play(buffer, buffer.last_event(GSKillViewClip.KIND_KILL), shown)


func advance(delta: float) -> void:
	if killcam != null:
		killcam.advance(delta)


func _on_frame(sample: Dictionary) -> void:
	moment.emit(float(sample.get("time", 0.0)))
	var v := GSKillViewClip.view_at(sample)
	state.emit(v["aux"])
	view.emit(v["transform"], v["fov"], v["cursor"], v["has_cursor"])


func _on_finished(skipped: bool) -> void:
	GSLog.debug(CHANNEL, "kill view over", {"skipped": skipped})
	finished.emit(skipped)
	if skipped:
		respawn_requested.emit()
		if respawn_fn.is_valid():
			respawn_fn.call()
