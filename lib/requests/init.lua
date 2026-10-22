-- Lua Requests library for http ease

local http_socket = require('socket.http')
local https_socket = require('ssl.https')
local url_parser = require('socket.url')
local ltn12 = require('ltn12')
local json = require('rapidjson')
local xml = require('xml')
local hmac = require('../../util.hmac')
local basexx = require('../../basexx')

local requests = {
    _DESCRIPTION = 'Http requests made simpler',
    http_socket = http_socket,
    https_socket = https_socket
}
local _requests = {}

--User facing function the make a request use Basic Authentication
function requests.HTTPBasicAuth(user, password)
    return {
        _type = 'basic',
        user = user,
        password = password
    }
end

function requests.post(url, args)
    return requests.request("POST", url, args)
end

function requests.get(url, args)
    return requests.request("GET", url, args)
end

function requests.delete(url, args)
    return requests.request("DELETE", url, args)
end

function requests.patch(url, args)
    return requests.request("PATCH", url, args)
end

function requests.put(url, args)
    return requests.request("PUT", url, args)
end

function requests.options(url, args)
    return requests.request("OPTIONS", url, args)
end

function requests.head(url, args)
    return requests.request("HEAD", url, args)
end

function requests.trace(url, args)
    return requests.request("TRACE", url, args)
end

--Sets up all the data for a request and makes the request
function requests.request(method, url, args)
    local request
    if type(url) == "table" then
        request = url
        if not request.url and request[1] then
            request.url = table.remove(request, 1)
        end
    else
        request = args or {}
        request.url = url
    end
    request.method = method
    _requests.parse_args(request)

    -- 我们不使用digest认证
    return _requests.make_request(request)
end

--Makes a request
function _requests.make_request(request)
    local response_body = {}
    local full_request = {
        method = request.method,
        url = request.url,
        headers = request.headers,
        sink = ltn12.sink.table(response_body),
        redirect = request.allow_redirects,
        proxy = request.proxy
    }

    if request.data then
        full_request.source = ltn12.source.string(request.data)
    end

    local response = {}
    local ok
    local socket = string.find(full_request.url, '^https:') and not request.proxy and https_socket or http_socket
    ok, response.status_code, response.headers, response.status = socket.request(full_request)

    assert(ok, 'error in '..request.method..' request: '..response.status_code)

    response.text = table.concat(response_body)
    response.json = function ()
        return json.decode(response.text)
    end
    response.xml = function ()
        return xml.load(response.text)
    end

    return response
end

--Parses through all the possible arguments for a request
function _requests.parse_args(request)
    _requests.check_url(request)
    _requests.check_data(request)
    _requests.create_header(request)
    _requests.check_timeout(request.timeout)
    _requests.check_redirect(request.allow_redirects)
end

--Format the the url based on the params argument
function _requests.format_params(url, params)
    if not params or next(params) == nil then
        return url
    end

    url = url..'?'
    for key, value in pairs(params) do
        if tostring(value) then
            url = url..tostring(key)..'='
            if type(value) == 'table' then
                local val_string = ''
                for _, val in ipairs(value) do
                    val_string = val_string..tostring(val)..','
                end
                url = url..val_string:sub(0, -2)
            else
                url = url..tostring(value)
            end
            url = url..'&'
        end
    end

    return url:sub(0, -2)
end

--Check that there is a URL given and append to it if params are passed in.
function _requests.check_url(request)
    assert(request.url, 'No url specified for request')
    request.url = _requests.format_params(request.url, request.params)
end

-- Add to the HTTP header
function _requests.create_header(request)
    request.headers = request.headers or {}
    if request.data then
        request.headers['Content-Length'] = request.data:len()
    end

    if request.cookies then
        if request.headers.cookie then
            request.headers.cookie = request.headers.cookie..'; '..request.cookies
        else
            request.headers.cookie = request.cookies
        end
    end

    if request.auth then
        _requests.add_auth_headers(request)
    end
end

--Makes sure that the data is in a format that can be sent
function _requests.check_data(request)
    if type(request.data) == "table" then
        request.data = json.encode(request.data)
    elseif request.data then
        request.data = tostring(request.data)
    end
end

--Set the timeout
function _requests.check_timeout(timeout)
    http_socket.TIMEOUT = timeout or 5
    https_socket.TIMEOUT = timeout or 5
end

--Checks is allow_redirects parameter is set correctly
function _requests.check_redirect(allow_redirects)
    if allow_redirects and type(allow_redirects) ~= "boolean" then
        error("allow_redirects expects a boolean value. received type = "..type(allow_redirects))
    end
end

--Create the Authorization header for Basic Auth
function _requests.basic_auth_header(request)
    local encoded = basexx.to_base64(request.auth.user..':'..request.auth.password)
    request.headers.Authorization = 'Basic '..encoded
end

-- Call the correct authentication header function
function _requests.add_auth_headers(request)
    if request.auth._type == 'basic' then
        _requests.basic_auth_header(request)
    end
end

--Return public functions
requests._private = _requests
return requests