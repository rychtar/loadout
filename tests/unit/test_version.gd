extends "res://tests/test_case.gd"

const Version := preload("res://addons/loadout/core/version.gd")


func _str(text: String) -> String:
	var version := Version.parse(text)
	return str(version) if version != null else "<null>"


func _cmp(a: String, b: String) -> int:
	return Version.parse(a).compare(Version.parse(b))


func test_parse_full() -> void:
	var version := Version.parse("1.2.3")
	check(version != null, "1.2.3 parses")
	if version != null:
		check_eq([version.major, version.minor, version.patch], [1, 2, 3], "parts")
		check_eq(version.prerelease, PackedStringArray(), "no prerelease")


func test_parse_lenient_forms() -> void:
	check_eq(_str("v1.2.3"), "1.2.3", "leading v")
	check_eq(_str("V2.0.0"), "2.0.0", "leading V")
	check_eq(_str(" 1.2.3 "), "1.2.3", "whitespace")
	check_eq(_str("1.2"), "1.2.0", "missing patch")
	check_eq(_str("3"), "3.0.0", "major only")
	check_eq(_str("1.0.0-beta.2"), "1.0.0-beta.2", "prerelease")
	check_eq(_str("1.0.0-rc.1+build.5"), "1.0.0-rc.1", "build metadata dropped")


func test_parse_invalid() -> void:
	for text: String in ["", "abc", "1.2.3.4", "01.2.3", "1.-2.3", "1.2.3-", "1..2", "^1.2.3"]:
		check(Version.parse(text) == null, "'%s' is invalid" % text)


func test_compare_numeric() -> void:
	check_eq(_cmp("1.2.3", "1.2.3"), 0, "equal")
	check_eq(_cmp("1.2.3", "1.2.4"), -1, "patch")
	check_eq(_cmp("1.10.0", "1.9.9"), 1, "minor compared numerically")
	check_eq(_cmp("2.0.0", "10.0.0"), -1, "major compared numerically")
	check_eq(_cmp("v1.2", "1.2.0"), 0, "normalized forms equal")


func test_compare_prerelease() -> void:
	# Order from the semver spec.
	var ordered: PackedStringArray = [
		"1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta",
		"1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0",
	]
	for i in ordered.size() - 1:
		check_eq(_cmp(ordered[i], ordered[i + 1]), -1, "%s < %s" % [ordered[i], ordered[i + 1]])
		check_eq(_cmp(ordered[i + 1], ordered[i]), 1, "%s > %s" % [ordered[i + 1], ordered[i]])


func test_caret_range() -> void:
	check(Version.satisfies("1.2.3", "^1.2.3"), "^ lower bound inclusive")
	check(Version.satisfies("1.9.0", "^1.2.3"), "^ allows minor")
	check(not Version.satisfies("2.0.0", "^1.2.3"), "^ excludes next major")
	check(not Version.satisfies("1.2.2", "^1.2.3"), "^ excludes lower")
	check(Version.satisfies("0.2.9", "^0.2.3"), "^0.x allows patch")
	check(not Version.satisfies("0.3.0", "^0.2.3"), "^0.x excludes next minor")
	check(Version.satisfies("0.0.3", "^0.0.3"), "^0.0.x exact patch")
	check(not Version.satisfies("0.0.4", "^0.0.3"), "^0.0.x excludes next patch")
	check(Version.satisfies("1.5.0", "^1"), "^1 partial")
	check(not Version.satisfies("0.9.0", "^1.2"), "^1.2 lower bound")


func test_tilde_range() -> void:
	check(Version.satisfies("1.2.9", "~1.2.3"), "~ allows patch")
	check(not Version.satisfies("1.3.0", "~1.2.3"), "~ excludes next minor")
	check(Version.satisfies("1.2.0", "~1.2"), "~1.2")
	check(Version.satisfies("1.9.0", "~1"), "~1 allows minor")
	check(not Version.satisfies("2.0.0", "~1"), "~1 excludes next major")


func test_exact_and_any() -> void:
	check(Version.satisfies("1.2.3", "1.2.3"), "exact")
	check(not Version.satisfies("1.2.4", "1.2.3"), "exact excludes other")
	check(Version.satisfies("1.2.7", "1.2"), "partial exact is 1.2.x")
	check(not Version.satisfies("1.3.0", "1.2"), "partial exact upper bound")
	check(Version.satisfies("7.1.0", "*"), "star")
	check(Version.satisfies("7.1.0", ""), "empty range is any")


func test_prereleases_need_opt_in() -> void:
	check(not Version.satisfies("2.0.0-beta.1", "^1.0.0"), "prerelease of next major")
	check(not Version.satisfies("1.5.0-rc.1", "^1.0.0"), "prerelease inside range")
	check(not Version.satisfies("1.5.0-rc.1", "*"), "star excludes prereleases")
	check(Version.satisfies("1.0.0-rc.2", "^1.0.0-rc.1"), "same tuple prerelease allowed")
	check(Version.satisfies("1.0.0", "^1.0.0-rc.1"), "release satisfies prerelease range")


func test_invalid_ranges() -> void:
	for text: String in ["^", "~", "^x", ">=1.0.0", "1.2.3 - 2.0.0", "^1.2.3.4", "latest"]:
		check(not Version.is_valid_range(text), "'%s' is invalid" % text)
		check(not Version.satisfies("1.2.3", text), "'%s' matches nothing" % text)
	for text: String in ["", "*", "1", "1.2", "1.2.3", "^1.2.3", "~0.1", "^1.0.0-beta.1"]:
		check(Version.is_valid_range(text), "'%s' is valid" % text)


func test_invalid_version_matches_nothing() -> void:
	check(not Version.satisfies("nonsense", "*"), "invalid version")


func test_max_satisfying() -> void:
	var versions: PackedStringArray = ["v1.0.0", "1.4.2", "v1.10.0", "2.0.0", "2.1.0-beta", "garbage"]
	check_eq(Version.max_satisfying(versions, "^1.0.0"), "v1.10.0", "highest 1.x keeps original text")
	check_eq(Version.max_satisfying(versions, "*"), "2.0.0", "star skips prerelease")
	check_eq(Version.max_satisfying(versions, "~1.4.0"), "1.4.2", "tilde")
	check_eq(Version.max_satisfying(versions, "^3.0.0"), "", "nothing matches")
