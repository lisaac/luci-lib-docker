require "nixio.util"
local json = require "luci.json"
local nixio = require "nixio"
local http = require "luci.http.protocol"
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
  local data, err_code, err_msg, data_f = docker_socket:readall()
  docker_socket:close()
  return data
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
  local res = send_http_socket(req_options.socket_path, gen_http_req(req_options))
  local code = string.match(res, "^HTTP/1.1 (.-) .-\r\n")
  local res_json_str = string.match(res, "[%[{].+[%]}]")
  return code, json.decode(res_json_str)
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
