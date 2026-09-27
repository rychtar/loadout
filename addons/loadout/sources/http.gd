@tool
class_name LoadoutHttp
extends RefCounted

## The only place that talks to the network. Every request is an HTTPRequest node added under
## the plugin node (no own threads). Only https:// URLs are allowed.

const TIMEOUT_S := 60.0
const MAX_BODY_BYTES := 256 * 1024 * 1024

var _parent: Node


func _init(parent: Node) -> void:
	_parent = parent


## GET request. Returns { "ok": bool, "error": String, "code": int,
## "headers": Dictionary (lower-case names), "body": PackedByteArray }.
## ok is false only when no HTTP answer arrived; check "code" for HTTP errors.
func get_request(url: String, headers: PackedStringArray = []) -> Dictionary:
	var refused := check_url(url)
	if refused != "":
		return _error(refused)
	if _parent == null or not _parent.is_inside_tree():
		return _error("The HTTP client is not attached to the editor.")
	var request := HTTPRequest.new()
	request.timeout = TIMEOUT_S
	request.body_size_limit = MAX_BODY_BYTES
	_parent.add_child(request)
	var err := request.request(url, headers)
	if err != OK:
		request.queue_free()
		return _error("Cannot send the request to %s: %s" % [url, error_string(err)])
	var response: Array = await request.request_completed
	request.queue_free()
	var result: int = response[0]
	if result != HTTPRequest.RESULT_SUCCESS:
		return _error("Connection to %s failed (%s)." % [url.get_slice("/", 2), _result_text(result)])
	return { "ok": true, "error": "", "code": response[1], "headers": _parse_headers(response[2]), "body": response[3] }


## "" when the URL may be requested, otherwise the reason.
func check_url(url: String) -> String:
	if not url.begins_with("https://"):
		return "Only HTTPS addresses are allowed: %s" % url
	return ""


func _error(message: String) -> Dictionary:
	return { "ok": false, "error": message, "code": 0, "headers": {}, "body": PackedByteArray() }


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
