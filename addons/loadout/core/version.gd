@tool
class_name LoadoutVersion
extends RefCounted

## Semantic version (major.minor.patch[-prerelease][+build]) and version ranges.
## Accepted versions are lenient: optional leading "v", missing minor/patch default to 0.
## Ranges: "" or "*" (any), "1.2.3" (exact), "1.2" (1.2.x), "^1.2.3", "~1.2.3".
## Prereleases only match a range whose own version is a prerelease of the same major.minor.patch.

const _VERSION_PATTERN := "^[vV]?(0|[1-9]\\d*)(?:\\.(0|[1-9]\\d*))?(?:\\.(0|[1-9]\\d*))?" \
		+ "(?:-([0-9A-Za-z-]+(?:\\.[0-9A-Za-z-]+)*))?(?:\\+[0-9A-Za-z-]+(?:\\.[0-9A-Za-z-]+)*)?$"

## Longer numbers would overflow an int.
const MAX_DIGITS := 9

static var _regex: RegEx

var major: int = 0
var minor: int = 0
var patch: int = 0
var prerelease: PackedStringArray = []
## How many numeric parts the parsed text had (1–3), used by partial ranges like "^1" or "1.2".
var precision: int = 3


## Returns null when text is not a version.
static func parse(text: String) -> LoadoutVersion:
	if _regex == null:
		_regex = RegEx.create_from_string(_VERSION_PATTERN)
	var found := _regex.search(text.strip_edges())
	if found == null:
		return null
	for group in 3:
		if found.get_string(group + 1).length() > MAX_DIGITS:
			return null
	var version := LoadoutVersion.new()
	version.major = found.get_string(1).to_int()
	version.precision = 1
	if found.get_string(2) != "":
		version.minor = found.get_string(2).to_int()
		version.precision = 2
	if found.get_string(3) != "":
		version.patch = found.get_string(3).to_int()
		version.precision = 3
	if found.get_string(4) != "":
		version.prerelease = found.get_string(4).split(".")
		for identifier in version.prerelease:
			# Numeric identifiers have no leading zeros (semver 2.0.0, rule 9).
			if identifier.length() > 1 and identifier.begins_with("0") and identifier.is_valid_int():
				return null
	return version


static func satisfies(version_text: String, range_text: String) -> bool:
	var version := parse(version_text)
	return version != null and version.matches(range_text)


static func is_valid_range(range_text: String) -> bool:
	return _bounds(range_text)["ok"]


## Highest version from versions that matches range_text, returned in its original form ("" if none).
static func max_satisfying(versions: PackedStringArray, range_text: String) -> String:
	var bounds := _bounds(range_text)
	var best_text := ""
	var best: LoadoutVersion = null
	if not bounds["ok"]:
		return best_text
	for text in versions:
		var version := parse(text)
		if version == null or not version._within(bounds):
			continue
		if best == null or version.compare(best) > 0:
			best = version
			best_text = text
	return best_text


func matches(range_text: String) -> bool:
	var bounds := _bounds(range_text)
	return bounds["ok"] and _within(bounds)


## Whether this version lies within bounds from _bounds() (which must be ok).
func _within(bounds: Dictionary) -> bool:
	var low: LoadoutVersion = bounds["min"]
	var high: LoadoutVersion = bounds["max"]
	if is_prerelease():
		if low == null or not low.is_prerelease() or not _same_numbers(low):
			return false
	if low != null and compare(low) < 0:
		return false
	if high != null and bounds["exact"]:
		return compare(high) == 0
	if high != null and compare(high) >= 0:
		return false
	return true


## -1, 0 or 1. Build metadata is ignored, prerelease precedence follows semver.
func compare(other: LoadoutVersion) -> int:
	if major != other.major:
		return signi(major - other.major)
	if minor != other.minor:
		return signi(minor - other.minor)
	if patch != other.patch:
		return signi(patch - other.patch)
	return _compare_prerelease(prerelease, other.prerelease)


func is_prerelease() -> bool:
	return not prerelease.is_empty()


func _to_string() -> String:
	var text := "%d.%d.%d" % [major, minor, patch]
	if is_prerelease():
		text += "-" + ".".join(prerelease)
	return text


func _same_numbers(other: LoadoutVersion) -> bool:
	return major == other.major and minor == other.minor and patch == other.patch


## { "ok": bool, "min": LoadoutVersion or null (inclusive), "max": LoadoutVersion or null, "exact": bool }.
## max is exclusive unless exact is true.
static func _bounds(range_text: String) -> Dictionary:
	var text := range_text.strip_edges()
	if text == "" or text == "*":
		return { "ok": true, "min": null, "max": null, "exact": false }
	var operator := ""
	if text.begins_with("^") or text.begins_with("~"):
		operator = text[0]
		text = text.substr(1)
	var low := parse(text)
	if low == null:
		return { "ok": false }
	var high := LoadoutVersion.new()
	match operator:
		"^":
			if low.major > 0 or low.precision == 1:
				high.major = low.major + 1
			elif low.minor > 0 or low.precision == 2:
				high.minor = low.minor + 1
			else:
				high.patch = low.patch + 1
		_:
			# "~1.2.3" and the partial "1.2" / "1" share the bound; a full version is exact.
			if operator == "" and low.precision == 3:
				return { "ok": true, "min": low, "max": low, "exact": true }
			high.major = low.major
			if low.precision == 1:
				high.major = low.major + 1
			else:
				high.minor = low.minor + 1
	return { "ok": true, "min": low, "max": high, "exact": false }


static func _compare_prerelease(a: PackedStringArray, b: PackedStringArray) -> int:
	if a.is_empty() or b.is_empty():
		return signi(int(a.is_empty()) - int(b.is_empty()))
	for i in mini(a.size(), b.size()):
		var a_numeric := a[i].is_valid_int()
		var b_numeric := b[i].is_valid_int()
		if a_numeric and b_numeric:
			var a_value := a[i].to_int()
			var b_value := b[i].to_int()
			if a_value != b_value:
				return -1 if a_value < b_value else 1
		elif a_numeric != b_numeric:
			return -1 if a_numeric else 1
		elif a[i] != b[i]:
			return -1 if a[i] < b[i] else 1
	if a.size() == b.size():
		return 0
	return -1 if a.size() < b.size() else 1
