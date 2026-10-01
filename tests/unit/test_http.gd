extends "res://tests/test_case.gd"

const Http := preload("res://addons/loadout/sources/http.gd")


func test_redirect_targets() -> void:
	var base := "https://api.github.com/repos/o/r/zipball/v1?x=1"
	check_eq(Http.redirect_target(base, "https://codeload.github.com/o/r/zip/v1"), "https://codeload.github.com/o/r/zip/v1", "absolute")
	check_eq(Http.redirect_target(base, "//cdn.example.com/a.zip"), "https://cdn.example.com/a.zip", "protocol relative stays https")
	check_eq(Http.redirect_target(base, "/repositories/1/zipball"), "https://api.github.com/repositories/1/zipball", "absolute path")
	check_eq(Http.redirect_target(base, "next.zip"), "https://api.github.com/repos/o/r/zipball/next.zip", "relative path")
	check_eq(Http.redirect_target(base, ""), "", "no location")
	check_eq(Http.redirect_target(base, "http://evil.example/a.zip"), "http://evil.example/a.zip", "kept as is so check_url refuses it")
	check_eq(Http.new(null).check_url("http://evil.example/a.zip") != "", true, "http is refused")


func test_credentials_are_dropped_for_another_host() -> void:
	var headers := PackedStringArray(["User-Agent: x", "Authorization: Bearer secret", "cookie: a=b", "Accept: */*"])
	check_eq(Http.without_credentials(headers), PackedStringArray(["User-Agent: x", "Accept: */*"]), "authorization and cookie removed")
