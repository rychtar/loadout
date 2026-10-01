extends "res://tests/test_case.gd"

const Http := preload("res://addons/loadout/sources/http.gd")
const FakeHttp := preload("res://tests/fake_http.gd")


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


func test_redirects_are_followed_without_credentials() -> void:
	var http := FakeHttp.new()
	http.responses["https://api.example.com/zip"] = { "code": 302, "headers": { "location": "https://cdn.example.com/a.zip" } }
	http.responses["https://cdn.example.com/a.zip"] = { "code": 200, "body": "zip" }
	var result: Dictionary = await http.get_request("https://api.example.com/zip", PackedStringArray(["User-Agent: x", "Authorization: Bearer t"]))
	check_eq(result["code"], 200, "final answer")
	check_eq((result["body"] as PackedByteArray).get_string_from_utf8(), "zip", "body of the last hop")
	check_eq(http.requests.size(), 2, "two hops")
	check_eq(http.header_of(0, "authorization"), "Bearer t", "token goes to the first host")
	check_eq(http.header_of(1, "authorization"), "", "and not to the redirect target")
	check_eq(http.header_of(1, "user-agent"), "x", "other headers stay")


func test_redirect_to_http_is_refused() -> void:
	var http := FakeHttp.new()
	http.responses["https://api.example.com/zip"] = { "code": 301, "headers": { "location": "http://evil.example/a.zip" } }
	var result: Dictionary = await http.get_request("https://api.example.com/zip")
	check(not result["ok"], "refused")
	check(result["error"].contains("HTTPS"), "says why: %s" % result["error"])


func test_redirect_loop_stops() -> void:
	var http := FakeHttp.new()
	http.responses["https://a.example/x"] = { "code": 302, "headers": { "location": "https://a.example/x" } }
	var result: Dictionary = await http.get_request("https://a.example/x")
	check(not result["ok"], "gives up")
	check_eq(http.requests.size(), Http.MAX_REDIRECTS + 1, "after the redirect limit")


func test_get_json() -> void:
	var http := FakeHttp.new()
	http.respond_json("https://a.example/ok", { "n": 1 })
	http.responses["https://a.example/bad"] = { "code": 200, "body": "not json" }
	http.responses["https://a.example/missing"] = { "code": 404, "body": "{}" }
	var ok: Dictionary = await http.get_json("https://a.example/ok")
	check_eq((ok["data"] as Dictionary).get("n"), 1.0, "parsed")
	check_eq((await http.get_json("https://a.example/bad"))["data"], null, "invalid JSON is null")
	var missing: Dictionary = await http.get_json("https://a.example/missing")
	check_eq(missing["data"], null, "no data for a non-200 answer")
	check_eq(missing["code"], 404, "code stays available")
