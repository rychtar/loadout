@tool
class_name LoadoutHttp
extends RefCounted

## The only place that talks to the network. Every request is an HTTPRequest node added under
## the plugin node (no own threads). Only https:// URLs are allowed.

const TIMEOUT_S := 60.0
const MAX_BODY_BYTES := 256 * 1024 * 1024
const MAX_REDIRECTS := 8
const REDIRECT_CODES: Array[int] = [301, 302, 303, 307, 308]

var _parent: Node


func _init(parent: Node) -> void:
	_parent = parent


## GET request. Redirects are followed here, not by HTTPRequest, so every hop is checked for
## https:// again and credentials never travel to another host.
## Returns { "ok": bool, "error": String, "code": int,
## "headers": Dictionary (lower-case names), "body": PackedByteArray }.
## ok is false only when no HTTP answer arrived; check "code" for HTTP errors.
func get_request(url: String, headers: PackedStringArray = []) -> Dictionary:
	var current := url
	var current_headers := headers
	for hop in MAX_REDIRECTS + 1:
		var response: Dictionary = await _request_once(current, current_headers)
		if not response["ok"] or not REDIRECT_CODES.has(response["code"]):
			return response
		var target := redirect_target(current, str(response["headers"].get("location", "")))
		if target == "":
			return _error("The redirect from %s has no usable address." % current.get_slice("/", 2))
		if _host(target) != _host(current):
			current_headers = without_credentials(current_headers)
		current = target
	return _error("Too many redirects from %s." % url.get_slice("/", 2))


## GET that expects a JSON body. Returns the get_request() result plus "data": the parsed body,
## null unless the answer is 200 with valid JSON (callers still check "code" for their own messages).
func get_json(url: String, headers: PackedStringArray = []) -> Dictionary:
	var response: Dictionary = await get_request(url, headers)
	response["data"] = null
	if response["ok"] and response["code"] == 200:
		response["data"] = JSON.parse_string((response["body"] as PackedByteArray).get_string_from_utf8())
	return response


## Absolute address a Location header points to, "" when it is empty.
static func redirect_target(base_url: String, location: String) -> String:
	if location == "":
		return ""
	if location.contains("://"):
		return location
	if location.begins_with("//"):
		return "https:" + location
	if location.begins_with("/"):
		return "https://" + _host(base_url) + location
	return base_url.split("?")[0].get_base_dir().path_join(location)


static func without_credentials(headers: PackedStringArray) -> PackedStringArray:
	var kept := PackedStringArray()
	for header in headers:
		var name := header.get_slice(":", 0).strip_edges().to_lower()
		if name != "authorization" and name != "cookie":
			kept.append(header)
	return kept


func _request_once(url: String, headers: PackedStringArray) -> Dictionary:
	var refused := check_url(url)
	if refused != "":
		return _error(refused)
	if _parent == null or not _parent.is_inside_tree():
		return _error("The HTTP client is not attached to the editor.")
	var request := HTTPRequest.new()
	request.timeout = TIMEOUT_S
	request.body_size_limit = MAX_BODY_BYTES
	request.max_redirects = 0
	_parent.add_child(request)
	var err := request.request(url, headers)
	if err != OK:
		request.queue_free()
		return _error("Cannot send the request to %s: %s" % [url, error_string(err)])
	var response: Array = await request.request_completed
	request.queue_free()
	var result: int = response[0]
	# With max_redirects = 0 Godot reports a redirect as RESULT_REDIRECT_LIMIT_REACHED but still hands
	# over the status code and headers, which is what get_request() needs to follow it by hand.
	var is_redirect := result == HTTPRequest.RESULT_REDIRECT_LIMIT_REACHED and REDIRECT_CODES.has(response[1])
	if result != HTTPRequest.RESULT_SUCCESS and not is_redirect:
		return _error("Connection to %s failed (%s)." % [_host(url), _result_text(result)])
	return { "ok": true, "error": "", "code": response[1], "headers": _parse_headers(response[2]), "body": response[3] }


## "" when the URL may be requested, otherwise the reason.
func check_url(url: String) -> String:
	if not url.begins_with("https://"):
		return "Only HTTPS addresses are allowed: %s" % url
	return ""


func _error(message: String) -> Dictionary:
	return { "ok": false, "error": message, "code": 0, "headers": {}, "body": PackedByteArray() }


static func _host(url: String) -> String:
	return url.get_slice("/", 2)


static func _parse_headers(lines: PackedStringArray) -> Dictionary:
	var headers := {}
	for line in lines:
		var colon := line.find(":")
		if colon > 0:
			headers[line.substr(0, colon).strip_edges().to_lower()] = line.substr(colon + 1).strip_edges()
	return headers


static func _result_text(result: int) -> String:
	match result:
		HTTPRequest.RESULT_CANT_CONNECT, HTTPRequest.RESULT_CANT_RESOLVE:
			return "cannot connect, are you offline?"
		HTTPRequest.RESULT_TIMEOUT:
			return "timed out"
		HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR:
			return "TLS error"
		HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED:
			return "answer too large"
		HTTPRequest.RESULT_REDIRECT_LIMIT_REACHED:
			return "too many redirects"
	return "code %d" % result
