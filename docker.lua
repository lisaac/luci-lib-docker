require "nixio.util"
local json = require "luci.json"
local nixio = require "nixio"
local http = require "luci.http.protocol"
local ltn12 = require "luci.ltn12"
--[[

  QUICK START:
  local docker = require "luci.docker"
  d = docker.new()
  code, res_table = d.container:list("containers_name")  --> code, res_table = d:list("containers_name")
  code, res_table = d.container:list(nil, {filters={name={"containers_name"}}})  --> code, res_table = d:list(nil, query_parameters)
  code, res_table = d.container:create("containers_name", query_parmeters, res_parameters)  --> code, res_table = d:create("containers_name", nil, res_parameters)
  code, res_table = d.network:list()
  .....

  https://docs.docker.com/engine/api

]]


local chunksource = function(sock, buffer)
	buffer = buffer or ""
	return function()
    local output
    --方法存在bug，需要修补
		local _, endp, count = buffer:find("^([0-9a-fA-F]+);?.-\r\n")
		while not count and #buffer <= 1024 do
			local newblock, code = sock:recv(1024 - #buffer)
			if not newblock then
				return nil, code
			end
			buffer = buffer .. newblock  
			_, endp, count = buffer:find("^([0-9a-fA-F]+);?.-\r\n")
		end
		count = tonumber(count, 16)
		if not count then
			return nil, -1, "invalid encoding"
		elseif count == 0 then
			-- 最后一行，结束
			return nil
		elseif count + 2 <= #buffer - endp then
			-- 当前不是最后一行，需要pumps继续处理，所以不要忘记buffer部分的处理
			output = buffer:sub(endp+1, endp+count)
			buffer = buffer:sub(endp+count+3)
			return output
		else
			-- buffer中的数据比count中的数据要少，需要从sock读取
			output = buffer:sub(endp+1, endp+count)
			buffer = ""
			if count - #output > 0 then
				local remain, code = sock:recvall(count-#output)
				if not remain then
					return nil, code
				end
				output = output .. remain
				count, code = sock:recvall(2)
			else
				count, code = sock:recvall(count+2-#buffer+endp)
			end
			if not count then
				return nil, code
			end
			return output
		end
	end
end

local docker_stream_filter = function(buffer)
  local output = ""
  buffer = buffer or ""
  if #buffer < 8 then
    return ""
  end
  local stream_type = ((string.byte(buffer, 1) == 1) and "stdout") or ((string.byte(buffer, 1) == 2) and "stderr") or ((string.byte(buffer, 1) == 0) and "stdin") or "stream_err"
  local valid_length =
    tonumber(string.byte(buffer, 5)) * 256 * 256 * 256 + tonumber(string.byte(buffer, 6)) * 256 * 256 + tonumber(string.byte(buffer, 7)) * 256 + tonumber(string.byte(buffer, 8))
  if valid_length > #buffer + 8 then
    return ""
  end
  return stream_type .. ": " .. string.sub(buffer, 9, valid_length + 8)
end

local gen_http_req = function(options)
  local req
  options = options or {}
  options.protocol = options.protocol or "HTTP/1.1"
  req = (options.method or "GET") .. " " .. options.path .. " " .. options.protocol .. "\r\n"
  req = req .. "Host: " .. options.host .. "\r\n"
  req = req .. "User-Agent: " .. options.user_agent .. "\r\n"
  if options.method == "POST" and type(options.conetnt) == "table" then
    local conetnt_json = json.encode(options.conetnt)
    req = req .. "Content-Type: application/json\r\n"
    req = req .. "Content-Length: " .. #conetnt_json .. "\r\n"
    req = req .. "\r\n" .. conetnt_json
  end
  req = req .. "Connection: close\r\n\r\n"
  return req
end

local send_http_socket = function(socket_path, req)
  local docker_socket = nixio.socket("unix", "stream")
  if docker_socket:connect(socket_path) ~= true then
    return 'HTTP/1.1 400 bad socket path\r\n{"message":"can\'t connect to unix socket"}'
  end
  if docker_socket:send(req) == 0 then
    return 'HTTP/1.1 400 send socket error\r\n{"message":"can\'t send data to unix socket"}'
  end
  -- local data, err_code, err_msg, data_f = docker_socket:readall()
  -- docker_socket:close()
  local linesrc = docker_socket:linesource() -- 读取 socket 将用 source http://w3.impa.br/~diego/software/luasocket/ltn12.html http://lua-users.org/wiki/FiltersSourcesAndSinks

  -- handle response header
  local line, code, error = linesrc()
  if not line then
    docker_socket:close()
    return {code = code, error = error}
  end
  local response = {code = 0, headers = {}, body = {}}

  local p, code, msg = line:match("^([%w./]+) ([0-9]+) (.*)")
  response.protocol = p
  response.code = tonumber(code)
  response.message = msg
  line = linesrc()
  while line and line ~= "" do
    local key, val = line:match("^([%w-]+)%s?:%s?(.*)")
    if key and key ~= "Status" then
      if type(response.headers[key]) == "string" then
        response.headers[key] = {response.headers[key], val}
      elseif type(response.headers[key]) == "table" then
        response.headers[key][#response.headers[key] + 1] = val
      else
        response.headers[key] = val
      end
    end
    line = linesrc()
  end
  -- handle response body
  local body_buffer = linesrc(true)
  if response.headers["Transfer-Encoding"] == "chunked" then
    local source = chunksource(docker_socket, body_buffer)
    code, error = ltn12.pump.all(source, (ltn12.sink.table(response.body))) and response.code or 555
    response.code = code
    response.error = error
  else
    response.body = json.decode(body_buffer)
  end
  docker_socket:close()
  return response
end

local send_http_require = function(options, method, path, operation, name_or_id, query_parameters, req_parameters)
  local par
  local req_options = setmetatable({}, {__index = options})

  query_parameters = query_parameters or {}
  req_parameters = req_parameters or {}
  if name_or_id == "" then
    name_or_id = nil
  end
  req_options.method = method
  req_options.path = "/" .. (path or "") .. (name_or_id and "/" .. name_or_id or "") .. (operation and "/" .. operation or "")
  if type(query_parameters) == "table" then
    for k, v in pairs(query_parameters) do
      if type(v) == "table" then
        par = (par and par .. "&" or "?") .. k .. "=" .. http.urlencode(json.encode(v))
      elseif type(v) == "boolean" then
        par = (par and par .. "&" or "?") .. k .. "=" .. (v and "true" or "false")
      elseif type(v) == "number" or type(v) == "string" then
        par = (par and par .. "&" or "?") .. k .. "=" .. v
      end
    end
  end
  req_options.path = req_options.path .. (par or "")
  if type(req_parameters) == "table" then
    req_options.conetnt = req_parameters
  end
  return send_http_socket(req_options.socket_path, gen_http_req(req_options))
end

local gen_api = function(_table, http_method, api_group, api_action)
  local _api_action
  if api_action ~= "list" and api_action ~= "inspect" and api_action ~= "remove" then
    _api_action = api_action
  elseif (api_group == "containers" or api_group == "images") and (api_action == "list" or api_action == "inspect") then
    _api_action = "json"
  end

  _table[api_group][api_action] = function(self, name_or_id, query_parameters, req_parameters)
    if api_action == "list" then
      if (name_or_id ~= "" or name_or_id ~= nil) then
        query_parameters = query_parameters or {}
        query_parameters.filters = query_parameters.filters or {}
        query_parameters.filters.name = query_parameters.filters.name or {}
        query_parameters.filters.name[#query_parameters.filters.name + 1] = name_or_id
        name_or_id = nil
      end
    elseif api_action == "create" then
      if (name_or_id ~= "" or name_or_id ~= nil) then
        query_parameters = query_parameters or {}
        query_parameters.name = query_parameters.name or name_or_id
        name_or_id = nil
      end
    elseif api_action == "logs" then
      local body_buffer = {}
      local response = send_http_require(self.options, http_method, api_group, _api_action, name_or_id, query_parameters, req_parameters)
      if response.code >= 200 and response.code < 300 then
        for i,v in ipairs(response.body) do
          body_buffer[#body_buffer+1] = docker_stream_filter(response.body[i])
        end
        response.body = body_buffer
      end
      return response
    end
    return send_http_require(self.options, http_method, api_group, _api_action, name_or_id, query_parameters, req_parameters)
  end
end

local _docker = {containers = {}, images = {}, networks = {}, volumes = {}}

gen_api(_docker, "GET", "containers", "list")
gen_api(_docker, "POST", "containers", "create")
gen_api(_docker, "GET", "containers", "inspect")
gen_api(_docker, "GET", "containers", "top")
gen_api(_docker, "GET", "containers", "logs")
gen_api(_docker, "GET", "containers", "changes")
gen_api(_docker, "GET", "containers", "stats")
gen_api(_docker, "POST", "containers", "resize")
gen_api(_docker, "POST", "containers", "start")
gen_api(_docker, "POST", "containers", "stop")
gen_api(_docker, "POST", "containers", "restart")
gen_api(_docker, "POST", "containers", "kill")
gen_api(_docker, "POST", "containers", "update")
gen_api(_docker, "POST", "containers", "rename")
gen_api(_docker, "POST", "containers", "pause")
gen_api(_docker, "POST", "containers", "unpause")
gen_api(_docker, "POST", "containers", "update")
gen_api(_docker, "DELETE", "containers", "remove")
gen_api(_docker, "POST", "containers", "prune")
gen_api(_docker, "POST", "containers", "exec")
-- TODO: export,attch, get, put

gen_api(_docker, "GET", "images", "list")
gen_api(_docker, "POST", "images", "create")
gen_api(_docker, "GET", "images", "inspect")
gen_api(_docker, "GET", "images", "history")
gen_api(_docker, "POST", "images", "tag")
gen_api(_docker, "DELETE", "images", "remove")
gen_api(_docker, "GET", "images", "search")
gen_api(_docker, "POST", "images", "prune")
-- TODO: build clear push commit export import

gen_api(_docker, "GET", "networks", "list")
gen_api(_docker, "GET", "networks", "inspect")
gen_api(_docker, "DELETE", "networks", "remove")
gen_api(_docker, "POST", "networks", "create")
gen_api(_docker, "POST", "networks", "connect")
gen_api(_docker, "POST", "networks", "disconnect")
gen_api(_docker, "POST", "networks", "prune")

function _docker.new(socket_path, host, version, user_agent, protocol)
  local docker = {}
  docker.options = {
    socket_path = socket_path or "/var/run/docker.sock",
    host = host or "localhost",
    version = version or "v1.40",
    user_agent = user_agent or "luci/0.12",
    protocol = protocol or "HTTP/1.1"
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
        if key == "options" then
          return docker.options
        end
      end
    }
  )
  setmetatable(
    docker.networks,
    {
      __index = function(t, key)
        if key == "options" then
          return docker.options
        end
      end
    }
  )
  setmetatable(
    docker.images,
    {
      __index = function(t, key)
        if key == "options" then
          return docker.options
        end
      end
    }
  )
  return docker
end

return _docker
