# Docker Engine API for LuCI

This is a simple Docker Engine API for LuCI, Now we can operation docker in LuCI by this lib.

QUICK START:
  ```
  local docker = require "luci.docker"
  d = docker.new()
  code, res_json_str = d.container:list("containers_name")  --> code, res_json_str = d:list("containers_name")
  code, res_json_str = d.container:list(nil, query_parameters)  --> code, res_json_str = d:list(nil, query_parameters)
  code, res_json_str = d.container:create("containers_name", querymeters, res_parameters)  --> code, res_json_str = d:create("containers_name", nil, res_parameters)
  code, res_json_str = d.network:list()
  .....
  ```

Parameters: https://docs.docker.com/engine/api