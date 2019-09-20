require "nixio.util"
local json = require "luci.json"
local nixio = require "nixio"
local http = require "luci.http.protocol"
--[[

  QUICK START:
  local docker = require "luci.docker"
  d = docker.new()
  code, res_json_str = d.container:list("containers_name")  --> code, res_json_str = d:list("containers_name")
  code, res_json_str = d.container:list(nil, query_parameters)  --> code, res_json_str = d:list(nil, query_parameters)
  code, res_json_str = d.container:create("containers_name", querymeters, res_parameters)  --> code, res_json_str = d:create("containers_name", nil, res_parameters)
  code, res_json_str = d.network:list()
  .....

  https://docs.docker.com/engine/api
  containers:
  LIST
    GET /containers/json?filter={filter}
    curl -v -sG --unix-socket /var/run/docker.sock http:/localhost/containers/json --data-urlencode 'filters={"name":["luci32", "luci"]}'
  START/STOP/RESTART
    POST /containers/{name}/start
    curl -v  --unix-socket /var/run/docker.sock  -X POST  http:/localhost/containers/dockertest/start
  RENAME
    POST /containers/{name}/rename
    curl -v  --unix-socket /var/run/docker.sock -X POST -d 'name=test2' http:/localhost/containers/testtt/rename
    curl -v  --unix-socket /var/run/docker.sock -X POST http:/localhost/containers/test2/rename --data-urlencode 'name=test1'
  EXEC
    POST /containers/{name}/exec
  DELETE
    DELETE /containers/{name}
    curl -v  --unix-socket /var/run/docker.sock  -X DELETE  http:/localhost/containers/test1
  CREATE
    POST /containers/create?name={name}
    curl -v --unix-socket /var/run/docker.sock -H "Content-Type: application/json"   -d '{ "Image": "alpine", "HostConfig": {"Binds": ["/dev:/dev:rslave", "/media/4t:/media/4t:rslave"]}, "Cmd": ["date"]}'  -X POST http:/v1.24/containers/create?name=test1

  socat - UNIX-CONNECT:/var/run/docker.sock

  POST /containers/create HTTP/1.1
  Host: v1.24
  Content-Type: application/json
  Content-Length: 106

  {"Image":"alpine","HostConfig":{"Binds":["/dev:/dev:rslave","/media/4t:/media/4t:rslave"]},"Cmd":["date"]}
]]

function gen_http_req (options)
  local tmp = ''
  options = options or {}
  options.protocol = options.protocol or 'HTTP/1.1'
  tmp = (options.method or 'GET') .. " " .. options.path .. ' ' .. options.protocol .. "\r\n"
  tmp = tmp .. 'Host: ' .. options.host .. "\r\n"
  tmp = tmp .. 'User-Agent: ' .. options.user_agent .. "\r\n"
  if options.method == 'POST' and type(options.conetnt) == 'table' then
    local conetnt_json = json.encode(options.conetnt)
    tmp = tmp .. "Content-Type: application/json\r\n"
    tmp = tmp .. "Content-Length: ".. #conetnt_json .. "\r\n"
    tmp = tmp .. "\r\n" .. conetnt_json
  end
  tmp = tmp .. "Connection: close\r\n\r\n"
  return tmp
end

function send_http_socket (socket_path, req)
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

function send_http_require(options, method, path, operation, name_or_id, query_parameters, req_parameters)
  query_parameters = query_parameters or {}
  req_parameters = req_parameters or {}
  local req_options = setmetatable({}, { __index = options })
  local par
  if name_or_id == '' then name_or_id = nil end
  req_options.method = method
  req_options.path = '/'.. (path or '') ..  (name_or_id and '/' .. name_or_id  or '') .. (operation and '/' .. operation or '')
  if type(query_parameters) == 'table' then
    for k, v in pairs(query_parameters) do
      if type(v) == 'table' then
        par = (par and par .. '&' or '?') .. k .. '=' .. http.urlencode(json.encode(v))
      elseif type(v) == 'boolean' then
        par = (par and par .. '&' or '?') .. k .. '=' .. (v and 'true' or 'false')
      elseif type(v) == 'number' or type(v) == 'string' then
        par = (par and par .. '&' or '?') .. k .. '=' .. v
      end
    end
  end
  req_options.path = req_options.path .. (par or '')
  if type(req_parameters) == 'table' then
    req_options.conetnt = req_parameters
  end
  local res = send_http_socket(req_options.socket_path, gen_http_req(req_options))
  local code = string.match(res, '^HTTP/1.1 (.-) .-\r\n')
  local res_json_str = string.match(res, '[%[{].+[%]}]')
  return code, res_json_str
end

local _docker = {
  custom = function(self, method, path, operation, name_or_id, query_parameters, req_parameters) 
    return send_http_require(self.options, method, path, operation, name_or_id, query_parameters, req_parameters)
  end,
  container = {
    start = function(self, name_or_id, query_parameters, req_parameters)
      return send_http_require(self.options, 'POST', 'containers', 'start', name_or_id, query_parameters, req_parameters)
    end,
    stop = function(self, name_or_id, query_parameters, req_parameters)
      return send_http_require(self.options, 'POST', 'containers', 'stop', name_or_id, query_parameters, req_parameters)
    end,
    restart = function(self, name_or_id, query_parameters, req_parameters)
      return send_http_require(self.options, 'POST', 'containers', 'restart', name, query_parameters, req_parameters)
    end,
    remove = function(self, name_or_id, query_parameters, req_parameters)
      return send_http_require(self.options, 'DELETE', 'containers', nil, name_or_id, query_parameters, req_parameters)
    end,
    list = function(self, name, query_parameters, req_parameters)
      if type(name) ~= nil and type(name) ~= '' then
        query_parameters = query_parameters or {}
        query_parameters.filters = query_parameters.filters or {}
        query_parameters.filters.name = query_parameters.filters.name or {}
        local exists = false
        for i, v in ipairs(query_parameters.filters.name) do
          if v == name then exists = true break end
        end
        if exists == false then
          query_parameters.filters.name[#query_parameters.filters.name+1] = name
        end
        name = nil
      end
      return send_http_require(self.options, 'GET', 'containers', 'json', nil, query_parameters, req_parameters)
    end,
    rename = function(self, name_or_id, query_parameters, req_parameters)
      return send_http_require(self.options, 'POST', 'containers', 'rename', name_or_id, query_parameters, req_parameters)
    end,
    exec = function(self, name_or_id, query_parameters, req_parameters)
      return send_http_require(self.options, 'POST', 'containers', 'exec', name_or_id, query_parameters, req_parameters)
    end,
    create = function(self, name, query_parameters, req_parameters)
      if type(name) ~= nil and type(name) ~= '' then
        query_parameters = query_parameters or {}
        query_parameters.name = name
        name = nil
      end
      return send_http_require(self.options, 'POST', 'containers', 'create', nil, query_parameters, req_parameters)
    end,
    wait = function(self, name_or_id, query_parameters, req_parameters)
      return send_http_require(self.options, 'POST', 'containers', 'wait', name_or_id, query_parameters, req_parameters)
    end
  },
  network = {
    list = function(self, name, query_parameters, req_parameters)
      if type(name) ~= nil and type(name) ~= '' then
        query_parameters = query_parameters or {}
        query_parameters.filters = query_parameters.filters or {}
        query_parameters.filters.name = query_parameters.filters.name or {}
        local exists = false
        for i, v in ipairs(query_parameters.filters.name) do
          if v == name then exists = true break end
        end
        if exists == false then
          query_parameters.filters.name[#query_parameters.filters.name+1] = name
        end
        name = nil
      end
      return send_http_require(self.options, 'GET', 'networks', nil, name, query_parameters, req_parameters)
    end,
    inspect  = function(self, name_or_id, query_parameters, req_parameters)
      return send_http_require(self.options, 'GET', 'networks', nil, name_or_id, query_parameters, req_parameters)
    end,
    remove  = function(self, name_or_id, query_parameters, req_parameters)
      return send_http_require(self.options, 'DELETE', 'networks', nil, name_or_id, query_parameters, req_parameters)
    end,
    create  = function(self, name, query_parameters, req_parameters)
      if type(name) ~= nil and type(name) ~= '' then
        query_parameters = query_parameters or {}
        query_parameters.name = name
        name = nil
      end
      return send_http_require(self.options, 'POST', 'networks', 'create', name, query_parameters, req_parameters)
    end,
    connect  = function(self, name_or_id, query_parameters, req_parameters)
      return send_http_require(self.options, 'DELETE', 'networks', 'connect', name_or_id, query_parameters, req_parameters)
    end,
    disconnect  = function(self, name_or_id, query_parameters, req_parameters)
      return send_http_require(self.options, 'DELETE', 'networks', 'disconnect', name_or_id, query_parameters, req_parameters)
    end
  },
  image={
    list = function(self, name_or_id, query_parameters, req_parameters)
      return send_http_require(self.options, 'GET', 'images', 'json', nil, query_parameters, req_parameters)
    end,
    create = function(self, name_or_id, query_parameters, req_parameters)
      return send_http_require(self.options, 'POST', 'images', 'create', name_or_id, query_parameters, req_parameters)
    end,
    remove = function(self, name_or_id, query_parameters, req_parameters)
      return send_http_require(self.options, 'DELETE', 'images', nil, name_or_id, query_parameters, req_parameters)
    end,
    search = function(self, name_or_id, query_parameters, req_parameters)
      return send_http_require(self.options, 'POST', 'images', 'search', nil, query_parameters, req_parameters)
    end
  }
}

function _docker:new(socket_path, host, version, user_agent, protocol)
  docker = {}
  docker.options = {
    socket_path = socket_path or '/var/run/docker.sock',
    host = host or 'localhost',
    version = version or 'v1.40',
    user_agent = user_agent or 'luci/0.12',
    protocol = protocol or 'HTTP/1.1'
  },
  setmetatable(docker, {__index = function (table, key)
    if _docker[key] ~= nil then
      return _docker[key]
    else
      return _docker.container[key]
    end
  end})
  setmetatable(docker.container, {__index = function(table, key)
    if key == 'options' then return docker.options end
  end})
  setmetatable(docker.network, {__index = function(table, key)
    if key == 'options' then return docker.options end
  end})
  setmetatable(docker.image, {__index = function(table, key)
    if key == 'options' then return docker.options end
  end})
  return docker
end

return _docker