class_name GSReplayRecorder
extends RefCounted

## The front door: what the server decided, tick by tick, on named channels. Not a Node.
## Call [method advance] at the top of each tick, before that tick's records, so a keyframe is the
## state after everything recorded before it. Records the authority's view, not a client's.

const CHANNEL := "replay"

## A chunk was sealed. Emitted for the file and the ring alike.
signal chunk_sealed(chunk: GSReplayChunk)

## Writing to the file stopped: a size limit or an I/O error. The ring, if any, carries on.
signal file_stopped(result: GSResult)

## Ticks a chunk may span before it is sealed. This is the most a crash can lose.
var chunk_ticks: int = 64

## Record bytes a chunk may hold before it is sealed, whatever its span.
var chunk_bytes: int = 256 << 10

## Ticks between automatic keyframes. 0: only the keyframes the game calls for.
var keyframe_interval_ticks: int = 640

## [code]func(tick: int) -> Variant[/code]: the game's whole state, as plain data. Called
## by [method advance]. Without one there are no automatic keyframes, and a seek replays
## from the first record — correct, and slow for a long match.
var keyframe_fn: Callable = Callable()

## A [code]GSReplayFormat.COMPRESSION_*[/code] mode.
var compression: int = GSReplayFormat.COMPRESSION_ZSTD

## A single record larger than this is refused.
var max_record_bytes: int = 1 << 20

## A file stops growing at this many bytes and is finished cleanly. 0 is unbounded.
var max_file_bytes: int = 0

## Where sealed chunks are also kept in memory, for [method save_clip]. Optional.
var ring: GSReplayRing = null

var header: GSReplayHeader = null
var writer: GSReplayWriter = null

var _key: PackedByteArray = PackedByteArray()
var _recording: bool = false
var _pending: Array[GSReplayRecord] = []
var _pending_bytes: int = 0
var _last_tick: int = -1
var _last_keyframe_tick: int = -1
var _records: int = 0
var _record_bytes: int = 0
var _keyframes: int = 0
var _refused: int = 0
var _chunks: int = 0


## Takes the chunking, keyframe, compression and size settings from [param config],
## converting its seconds with [param tick_rate].
func configure(config: GSReplayConfig, tick_rate: int) -> GSResult:
	var valid := config.validate()
	if not valid.ok:
		return valid
	chunk_ticks = maxi(1, int(round(config.chunk_seconds * tick_rate)))
	chunk_bytes = config.chunk_kib << 10
	keyframe_interval_ticks = int(round(config.keyframe_seconds * tick_rate))
	compression = GSReplayFormat.compression_from_name(config.compression)
	max_record_bytes = config.max_record_kib << 10
	max_file_bytes = config.max_file_mib << 20
	if config.ring_seconds > 0.0:
		if ring == null:
			ring = GSReplayRing.new()
		ring.window_ticks = int(ceil(config.ring_seconds * tick_rate))
		ring.max_bytes = config.ring_max_mib << 20
	else:
		ring = null
	return GSResult.success(self)


## Begins recording. [param path] empty records to the ring only, which is how a server
## keeps evidence without writing every match to disk.
func start(p_header: GSReplayHeader, path: String = "", key: PackedByteArray = PackedByteArray()) -> GSResult:
	if _recording:
		return GSResult.fail(GSError.CODE_STATE, "Already recording.")
	var valid := p_header.validate()
	if not valid.ok:
		return valid
	if path == "" and ring == null:
		return GSResult.fail(GSError.CODE_INVALID, "Nothing to record to: give a path, a ring, or both.")
	header = p_header
	_key = key
	writer = null
	if path != "":
		var w := GSReplayWriter.new()
		w.max_file_bytes = max_file_bytes
		var opened := w.open(path, header, key)
		if not opened.ok:
			return opened.wrap("Could not start recording.")
		writer = w
	_recording = true
	_pending.clear()
	_pending_bytes = 0
	_last_tick = -1
	_last_keyframe_tick = -1
	GSLog.info(CHANNEL, "recording", {
		"game": header.game, "map": header.map, "path": path if path != "" else "(ring only)",
	})
	return GSResult.success(self)


func is_recording() -> bool:
	return _recording


func is_recording_to_file() -> bool:
	return _recording and writer != null and writer.is_open()


## Call at the top of every server tick, before anything of that tick is recorded. Seals a
## chunk that has run long and takes an automatic keyframe when one is due.
func advance(tick: int) -> GSResult:
	if not _recording:
		return GSResult.fail(GSError.CODE_STATE, "Not recording.")
	if tick < _last_tick:
		return _refuse_backwards(tick)
	var sealed := GSResult.success(null)
	if not _pending.is_empty() and tick - _pending[0].tick >= chunk_ticks:
		sealed = _seal()
	if keyframe_fn.is_valid() and keyframe_interval_ticks > 0 \
			and (_last_keyframe_tick < 0 or tick - _last_keyframe_tick >= keyframe_interval_ticks):
		var state: Variant = keyframe_fn.call(tick)
		var kf := keyframe(tick, state)
		if not kf.ok:
			return kf
	return sealed


## Records opaque bytes. The cheapest path, and the one a netcode snapshot takes.
func record(tick: int, channel: StringName, data: PackedByteArray) -> GSResult:
	return _append(GSReplayRecord.new(tick, channel, data, 0))


## Records a plain-data Variant — a Dictionary, an Array, numbers, strings, vectors.
## Objects are refused: see [method GSReplayFormat.contains_object].
func record_value(tick: int, channel: StringName, value: Variant) -> GSResult:
	if GSReplayFormat.contains_object(value):
		_refused += 1
		return GSResult.fail(
			GSError.CODE_INVALID,
			"A replay record holds plain data only.",
			"channel %s at tick %d carried an object" % [channel, tick]
		)
	return _append(GSReplayRecord.new(tick, channel, var_to_bytes(value), GSReplayRecord.FLAG_VARIANT))


## Records the whole state at [param tick] — the state after every record so far. Seals
## the current chunk and begins the next with it, which is what makes it seekable.
func keyframe(tick: int, state: Variant) -> GSResult:
	if not _recording:
		return GSResult.fail(GSError.CODE_STATE, "Not recording.")
	if tick < _last_tick:
		return _refuse_backwards(tick)
	if GSReplayFormat.contains_object(state):
		_refused += 1
		return GSResult.fail(GSError.CODE_INVALID, "A keyframe holds plain data only.", "tick %d" % tick)
	var sealed := GSResult.success(null)
	if not _pending.is_empty():
		sealed = _seal()
	var r := GSReplayRecord.new(
		tick, GSReplayFormat.KEYFRAME_CHANNEL, var_to_bytes(state),
		GSReplayRecord.FLAG_VARIANT | GSReplayRecord.FLAG_KEYFRAME
	)
	_pending.append(r)
	_pending_bytes += r.data.size()
	_last_tick = tick
	_last_keyframe_tick = tick
	_keyframes += 1
	return sealed


func _append(r: GSReplayRecord) -> GSResult:
	if not _recording:
		return GSResult.fail(GSError.CODE_STATE, "Not recording.")
	if r.channel == &"" or r.channel == GSReplayFormat.KEYFRAME_CHANNEL:
		_refused += 1
		return GSResult.fail(GSError.CODE_INVALID, "That channel name is not available.", "'%s'" % r.channel)
	if r.tick < _last_tick:
		return _refuse_backwards(r.tick)
	if r.data.size() > max_record_bytes:
		_refused += 1
		return GSResult.fail(
			GSError.CODE_QUOTA,
			"A replay record is larger than the limit.",
			"channel %s at tick %d: %d bytes, limit %d" % [r.channel, r.tick, r.data.size(), max_record_bytes]
		)
	var sealed := GSResult.success(null)
	if not _pending.is_empty() and (
		r.tick - _pending[0].tick >= chunk_ticks or _pending_bytes + r.data.size() > chunk_bytes
	):
		sealed = _seal()
	_pending.append(r)
	_pending_bytes += r.data.size()
	_last_tick = r.tick
	_records += 1
	_record_bytes += r.data.size()
	return sealed


func _refuse_backwards(tick: int) -> GSResult:
	_refused += 1
	# Refused rather than sorted in: every seek and every chunk boundary assumes the stream
	# only moves forward, and a record that arrives late is a bug in the caller's tick.
	return GSResult.fail(
		GSError.CODE_INVALID,
		"Replay ticks only move forward.",
		"tick %d after %d" % [tick, _last_tick]
	)


## Seals the pending records into a chunk and hands it to the file and the ring.
func _seal() -> GSResult:
	if _pending.is_empty():
		return GSResult.success(null)
	var chunk := GSReplayChunk.build(_pending, compression)
	_pending.clear()
	_pending_bytes = 0
	_chunks += 1

	var result := GSResult.success(chunk)
	if writer != null and writer.is_open():
		var wrote := writer.write_chunk(chunk)
		if not wrote.ok:
			# Finish what is there so the file on disk is complete and verifiable rather than
			# a truncated one that reads like a crash.
			var finished := writer.finish()
			GSLog.warn(CHANNEL, "replay file stopped", {
				"path": writer.path, "why": str(wrote.error),
				"finished": finished.ok,
			})
			file_stopped.emit(wrote)
			result = wrote
	if ring != null:
		ring.push(chunk)
	chunk_sealed.emit(chunk)
	return result


## Seals whatever is pending now. A host about to do something risky can call this so a
## crash loses nothing recorded so far.
func flush() -> GSResult:
	return _seal()


## Stops recording, finishing the file. Returns the file's evidence Dictionary, or an
## empty one when recording only to the ring.
func stop() -> GSResult:
	if not _recording:
		return GSResult.fail(GSError.CODE_STATE, "Not recording.")
	var sealed := _seal()
	_recording = false
	var evidence := {}
	if writer != null:
		var done := writer.finish()
		if not done.ok:
			return done
		evidence = done.value
	GSLog.info(CHANNEL, "recording stopped", {
		"records": _records, "keyframes": _keyframes, "chunks": _chunks, "refused": _refused,
	})
	if not sealed.ok and sealed.code() != GSError.CODE_QUOTA:
		return sealed
	return GSResult.success(evidence)


## Writes the last [param seconds] of the ring to [param path] as a complete replay.
## Seals what is pending first, so the clip runs up to the last thing recorded. The clip is
## keyed with the recording's key unless [param key] names another.
func save_clip(path: String, seconds: float = 0.0, key: PackedByteArray = PackedByteArray()) -> GSResult:
	if ring == null:
		return GSResult.fail(GSError.CODE_STATE, "This recorder has no ring to save from.")
	if header == null:
		return GSResult.fail(GSError.CODE_STATE, "Nothing has been recorded.")
	_seal()
	return ring.save(path, header, seconds, key if not key.is_empty() else _key)


func describe() -> Dictionary:
	return {
		"recording": _recording,
		"to_file": is_recording_to_file(),
		"records": _records,
		"record_bytes": _record_bytes,
		"keyframes": _keyframes,
		"chunks": _chunks,
		"refused": _refused,
		"pending": _pending.size(),
		"last_tick": _last_tick,
	}


func describe_lines() -> PackedStringArray:
	var d := describe()
	var lines := PackedStringArray([
		"replay recorder: %s, %d record(s) in %d chunk(s), %d keyframe(s), %d refused, last tick %d" % [
			"recording" if _recording else "stopped", d["records"], d["chunks"],
			d["keyframes"], d["refused"], _last_tick,
		],
	])
	if writer != null:
		lines.append_array(writer.describe_lines())
	if ring != null:
		lines.append_array(ring.describe_lines())
	return lines
