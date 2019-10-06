require 'nixio.util'
local json = require 'luci.json'
local nixio = require 'nixio'
local http = require 'luci.http.protocol'
local ltn12 = require 'luci.ltn12'
local fs = require 'nixio.fs'
local chunksource = function(sock, buffer)
  buffer = buffer or ''
  return function()
    local output
    local _, endp, count = buffer:find('^([0-9a-fA-F]+);?.-\r\n')
    if not count then -- lua  ^ only match start of stirng，not start of line
      _, endp, count = buffer:find('\r\n([0-9a-fA-F]+);?.-\r\n')
    end
    while not count do
      local newblock, code = sock:recv(1024)
      if not newblock then
        return nil, code
      end
      buffer = buffer .. newblock
      _, endp, count = buffer:find('^([0-9a-fA-F]+);?.-\r\n')
      if not count then
        _, endp, count = buffer:find('\r\n([0-9a-fA-F]+);?.-\r\n')
      end
    end
    count = tonumber(count, 16)
    if not count then
      return nil, -1, 'invalid encoding'
    elseif count == 0 then -- finial
      return nil
    elseif count + 2 <= #buffer - endp then
      output = buffer:sub(endp + 1, endp + count)
      buffer = buffer:sub(endp + count + 3) -- don't forget handle buffer
      return output
    else
      output = buffer:sub(endp + 1, endp + count)
      buffer = ''
      if count > #output then
        local remain, code = sock:recvall(count - #output) --need read remaining
        if not remain then
          return nil, code
        end
        output = output .. remain
        count, code = sock:recvall(2) --read \r\n
      else
        count, code = sock:recvall(count + 2 - #buffer + endp)
      end
      if not count then
        return nil, code
      end
      return output
    end
  end
end

local docker_stream_filter = function(buffer)
  buffer = buffer or ''
  if #buffer < 8 then
    return ''
  end
  local stream_type =
    ((string.byte(buffer, 1) == 1) and 'stdout') or ((string.byte(buffer, 1) == 2) and 'stderr') or
    ((string.byte(buffer, 1) == 0) and 'stdin') or
    'stream_err'
  local valid_length =
    tonumber(string.byte(buffer, 5)) * 256 * 256 * 256 + tonumber(string.byte(buffer, 6)) * 256 * 256 +
    tonumber(string.byte(buffer, 7)) * 256 +
    tonumber(string.byte(buffer, 8))
  if valid_length > #buffer + 8 then
    return ''
  end
  return stream_type .. ': ' .. string.sub(buffer, 9, valid_length + 8)
  -- return string.sub(buffer, 9, valid_length + 8)
end

local gen_http_req = function(options)
  local req
  options = options or {}
  options.protocol = options.protocol or 'HTTP/1.1'
  req = (options.method or 'GET') .. ' ' .. options.path .. ' ' .. options.protocol .. '\r\n'
  req = req .. 'Host: ' .. options.host .. '\r\n'
  req = req .. 'User-Agent: ' .. options.user_agent .. '\r\n'
  req = req .. 'Connection: close\r\n'
  if options.method == 'POST' and type(options.conetnt) == 'table' then
    local conetnt_json = json.encode(options.conetnt)
    req = req .. 'Content-Type: application/json\r\n'
    req = req .. 'Content-Length: ' .. #conetnt_json .. '\r\n'
    req = req .. '\r\n' .. conetnt_json
  else
    req = req .. '\r\n'
  end
  return req
end

local send_http_socket = function(socket_path, req)
  local docker_socket = nixio.socket('unix', 'stream')
  if docker_socket:connect(socket_path) ~= true then
    return "HTTP/1.1 400 bad socket path\r\n{\"message\":\"can't connect to unix socket\"}"
  end
  if docker_socket:send(req) == 0 then
    return "HTTP/1.1 400 send socket error\r\n{\"message\":\"can't send data to unix socket\"}"
  end
  -- local data, err_code, err_msg, data_f = docker_socket:readall()
  -- docker_socket:close()
  local linesrc = docker_socket:linesource()
  -- read socket using source http://w3.impa.br/~diego/software/luasocket/ltn12.html
  --http://lua-users.org/wiki/FiltersSourcesAndSinks

  -- handle response header
  local line = linesrc()
  if not line then
    docker_socket:close()
    return {code = 554}
  end
  local response = {code = 0, headers = {}, body = {}}

  local p, code, msg = line:match('^([%w./]+) ([0-9]+) (.*)')
  response.protocol = p
  response.code = tonumber(code)
  response.message = msg
  line = linesrc()
  while line and line ~= '' do
    local key, val = line:match('^([%w-]+)%s?:%s?(.*)')
    if key and key ~= 'Status' then
      if type(response.headers[key]) == 'string' then
        response.headers[key] = {response.headers[key], val}
      elseif type(response.headers[key]) == 'table' then
        response.headers[key][#response.headers[key] + 1] = val
      else
        response.headers[key] = val
      end
    end
    line = linesrc()
  end
  -- handle response body
  local body_buffer = linesrc(true)
  response.body = {}
  if response.headers['Transfer-Encoding'] == 'chunked' then
    local source = chunksource(docker_socket, body_buffer)
    code = ltn12.pump.all(source, (ltn12.sink.table(response.body))) and response.code or 555
    response.code = code
  else
    local body_source = ltn12.source.cat(ltn12.source.string(body_buffer), docker_socket:blocksource())
    code = ltn12.pump.all(body_source, (ltn12.sink.table(response.body))) and response.code or 555
    response.code = code
  end
  docker_socket:close()
  return response
end

local send_http_require = function(options, method, api_group, api_action, name_or_id, request_qurey, request_body)
  local qurey
  local req_options = setmetatable({}, {__index = options})

  -- for docker action status
  fs.writefile(options.status_path, api_group .. " " .. api_action .. " " .. name_or_id)

  request_qurey = request_qurey or {}
  request_body = request_body or {}
  if name_or_id == '' then
    name_or_id = nil
  end
  req_options.method = method
  req_options.path =
    '/' .. (api_group or '') .. (name_or_id and '/' .. name_or_id or '') .. (api_action and '/' .. api_action or '')
  if type(request_qurey) == 'table' then
    for k, v in pairs(request_qurey) do
      if type(v) == 'table' then
        qurey = (qurey and qurey .. '&' or '?') .. k .. '=' .. http.urlencode(json.encode(v))
      elseif type(v) == 'boolean' then
        qurey = (qurey and qurey .. '&' or '?') .. k .. '=' .. (v and 'true' or 'false')
      elseif type(v) == 'number' or type(v) == 'string' then
        qurey = (qurey and qurey .. '&' or '?') .. k .. '=' .. v
      end
    end
  end
  req_options.path = req_options.path .. (qurey or '')
  if type(request_body) == 'table' then
    req_options.conetnt = request_body
  end
  local response = send_http_socket(req_options.socket_path, gen_http_req(req_options))
  -- for docker action status
  fs.remove(options.status_path)
  return response
end

local gen_api = function(_table, http_method, api_group, api_action)
  local _api_action
  if api_action ~= 'list' and api_action ~= 'inspect' and api_action ~= 'remove' then
    _api_action = api_action
  elseif (api_group == 'containers' or api_group == 'images' or api_group == 'exec') and (api_action == 'list' or api_action == 'inspect') then
    _api_action = 'json'
  end

  _table[api_group][api_action] = function(self, name_or_id, request_qurey, request_body)
    if api_action == 'list' then
      if (name_or_id ~= '' or name_or_id ~= nil) then
        if api_group == "images" then
          name_or_id = nil
        else
          request_qurey = request_qurey or {}
          request_qurey.filters = request_qurey.filters or {}
          request_qurey.filters.name = request_qurey.filters.name or {}
          request_qurey.filters.name[#request_qurey.filters.name + 1] = name_or_id
          name_or_id = nil
        end
      end
    elseif api_action == 'create' then
      if (name_or_id ~= '' or name_or_id ~= nil) then
        request_qurey = request_qurey or {}
        request_qurey.name = request_qurey.name or name_or_id
        name_or_id = nil
      end
    elseif api_action == 'logs' then
      local body_buffer = ""
      local response =
        send_http_require(
        self.options,
        http_method,
        api_group,
        _api_action,
        name_or_id,
        request_qurey,
        request_body
      )
      if response.code >= 200 and response.code < 300 then
        for i, v in ipairs(response.body) do
          body_buffer = body_buffer .. docker_stream_filter(response.body[i])
        end
        response.body = body_buffer
      end
      return response
    end
    local response = send_http_require(
      self.options,
      http_method,
      api_group,
      _api_action,
      name_or_id,
      request_qurey,
      request_body
    )
    if response.headers["Content-Type"] == "application/json" then
      response.body = json.decode(response.body[1])
    end
    return response
  end
end

local _docker = {containers = {}, exec = {}, images = {}, networks = {}, volumes = {}}

gen_api(_docker, 'GET', 'containers', 'list')
gen_api(_docker, 'POST', 'containers', 'create')
gen_api(_docker, 'GET', 'containers', 'inspect')
gen_api(_docker, 'GET', 'containers', 'top')
gen_api(_docker, 'GET', 'containers', 'logs')
gen_api(_docker, 'GET', 'containers', 'changes')
gen_api(_docker, 'GET', 'containers', 'stats')
gen_api(_docker, 'POST', 'containers', 'resize')
gen_api(_docker, 'POST', 'containers', 'start')
gen_api(_docker, 'POST', 'containers', 'stop')
gen_api(_docker, 'POST', 'containers', 'restart')
gen_api(_docker, 'POST', 'containers', 'kill')
gen_api(_docker, 'POST', 'containers', 'update')
gen_api(_docker, 'POST', 'containers', 'rename')
gen_api(_docker, 'POST', 'containers', 'pause')
gen_api(_docker, 'POST', 'containers', 'unpause')
gen_api(_docker, 'POST', 'containers', 'update')
gen_api(_docker, 'DELETE', 'containers', 'remove')
gen_api(_docker, 'POST', 'containers', 'prune')
gen_api(_docker, 'POST', 'containers', 'exec')
gen_api(_docker, 'POST', 'exec', 'start')
gen_api(_docker, 'POST', 'exec', 'resize')
gen_api(_docker, 'GET', 'exec', 'inspect')
-- TODO: export,attch, get, put

gen_api(_docker, 'GET', 'images', 'list')
gen_api(_docker, 'POST', 'images', 'create')
gen_api(_docker, 'GET', 'images', 'inspect')
gen_api(_docker, 'GET', 'images', 'history')
gen_api(_docker, 'POST', 'images', 'tag')
gen_api(_docker, 'DELETE', 'images', 'remove')
gen_api(_docker, 'GET', 'images', 'search')
gen_api(_docker, 'POST', 'images', 'prune')
-- TODO: build clear push commit export import

gen_api(_docker, 'GET', 'networks', 'list')
gen_api(_docker, 'GET', 'networks', 'inspect')
gen_api(_docker, 'DELETE', 'networks', 'remove')
gen_api(_docker, 'POST', 'networks', 'create')
gen_api(_docker, 'POST', 'networks', 'connect')
gen_api(_docker, 'POST', 'networks', 'disconnect')
gen_api(_docker, 'POST', 'networks', 'prune')

function _docker.new(socket_path, host, version, user_agent, protocol)
  local docker = {}
  docker.options = {
    socket_path = socket_path or '/var/run/docker.sock',
    host = host or 'localhost',
    version = version or 'v1.40',
    user_agent = user_agent or 'luci/0.12',
    protocol = protocol or 'HTTP/1.1',
    status_path = status_path or '/tmp/.docker_action_status'
  }
  setmetatable(
    docker,
    {
      __index = function(t, key)
        if _docker[key] ~= nil then
          return _docker[key]
        else
          return _docker.containers[key]
        end
      end
    }
  )
  setmetatable(
    docker.containers,
    {
      __index = function(t, key)
        if key == 'options' then
          return docker.options
        end
      end
    }
  )
  setmetatable(
    docker.networks,
    {
      __index = function(t, key)
        if key == 'options' then
          return docker.options
        end
      end
    }
  )
  setmetatable(
    docker.images,
    {
      __index = function(t, key)
        if key == 'options' then
          return docker.options
        end
      end
    }
  )
  setmetatable(
    docker.exec,
    {
      __index = function(t, key)
        if key == 'options' then
          return docker.options
        end
      end
    }
  )
  return docker
end

return _docker
