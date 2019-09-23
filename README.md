# Docker Engine API for LuCI

This is a simple Docker Engine API for LuCI, Now we can operating Docker in LuCI by this lib.

QUICK START:
```lua
local docker = require "luci.docker"
d = docker.new()
response_str = d.container:list("containers_name") 
-- if operate container, just using: d:list("containers_name")
-- return an response(table type) like this:
{
    message = OK
    protocol = HTTP/1.1
    code = 200
    headers = {
      Ostype = linux
      Content-Type = application/json
      Api-Version = 1.40
      Connection = close
      Date = Mon, 23 Sep 2019 10:30:50 GMT
      Content-Length = 788
      Docker-Experimental = false
      Server = Docker/19.03.1 (linux)
    }
    body = {
      1 = [{"Id":"611e39220db324d38bfae8cdc6bc5bff15095bd4c15d2c3a7d18b193ddfc0ccf","Names":["/docker_api_test"],"Image":"alpine","ImageID":"sha256:cdf98d1859c1beb33ec70507249d34bacf888d59c24df3204057f9a6c758dddb","Command":"sh","Created":1569234629,"Ports":[],"Labels":{},"State":"running","Status":"Up 18 seconds","HostConfig":{"NetworkMode":"default"},"NetworkSettings":{"Networks":{"bridge":{"IPAMConfig":null,"Links":null,"Aliases":null,"NetworkID":"9ee156d0a5ea578cbb45d38491452bb0f5c57bf477008240b0c6784c25363607","EndpointID":"ec540182d3fd8fed3d88eabd6bc4113f69e3eaef2fc057d7752ea282e5cad15b","Gateway":"172.17.0.1","IPAddress":"172.17.0.6","IPPrefixLen":16,"IPv6Gateway":"","GlobalIPv6Address":"","GlobalIPv6PrefixLen":0,"MacAddress":"02:42:ac:11:00:06","DriverOpts":null}}},"Mounts":[]}]

    }
  }

response = d.container:list(nil, query_parameters)
response = d.container:create("containers_name", querymeters, res_parameters)
response = d.network:list()
.....
```

Parameters: https://docs.docker.com/engine/api