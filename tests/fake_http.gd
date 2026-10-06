extends LoadoutHttp
## LoadoutHttp without network: canned responses per URL, records every request.

## url -> { "code": int, "headers": Dictionary, "body": PackedByteArray or String } or "error" text
var responses: Dictionary[String, Variant] = {}
## [{ "url": String, "headers": PackedStringArray, "timeout": float }]
var requests: Array[Dictionary] = []


func _init() -> void:
	super(null)


func respond_json(url: String, data: Variant, headers: Dictionary = {}, code: int = 200) -> void:
	responses[url] = { "code": code, "headers": headers, "body": JSON.stringify(data) }


## Replaces the transport only, so redirect handling of LoadoutHttp.get_request() runs for real.
func _request_once(url: String, headers: PackedStringArray, timeout_s: float) -> Dictionary:
	requests.append({ "url": url, "headers": headers, "timeout": timeout_s })
	var refused := check_url(url)
	if refused != "":
		return _error(refused)
	if not responses.has(url):
		return _error("No response for %s." % url)
	var response: Variant = responses[url]
	if typeof(response) == TYPE_STRING:
		return _error(response)
	var body: Variant = response.get("body", PackedByteArray())
	return {
		"ok": true, "error": "", "code": response.get("code", 200), "headers": response.get("headers", {}),
		"body": body.to_utf8_buffer() if typeof(body) == TYPE_STRING else body,
	}


func header_of(index: int, name: String) -> String:
	for header: String in requests[index]["headers"]:
		if header.to_lower().begins_with(name.to_lower() + ":"):
			return header.substr(header.find(":") + 1).strip_edges()
	return ""
