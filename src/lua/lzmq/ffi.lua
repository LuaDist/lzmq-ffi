
local api = require "lzmq.ffi.api"
local ffi = require "ffi"

local make_weak_k do
  local mt = {__mode = "k"}
  make_weak_k = function() 
    return setmetatable({}, mt)
  end
end

local make_weak_kv do
  local mt = {__mode = "kv"}
  make_weak_kv = function() 
    return setmetatable({}, mt)
  end
end

local FLAGS = api.FLAGS

local ptrtoint = api.ptrtoint

local zmq     = {}
local Error   = {}
local Context = {}
local Socket  = {}
local Message = {}
local Poller  = {}


local function zerror(...) return Error:new(...) end

do -- Error
Error.__index = Error

function Error:new(no)
  local o = setmetatable({
    errno = no or api.zmq_errno();
  }, self)
  return o
end

function Error:no()
  return self.errno
end

function Error:msg()
  return api.zmq_strerror(self.errno)
end

function Error:mnemo()
  return api.zmq_mnemoerror(self.errno)
end

function Error:__tostring()
  return string.format("[%s] %s (%d)", self:mnemo(), self:msg(), self:no())
end

end

do -- Context
Context.__index = Context

function Context:new(ptr)
  local ctx
  if ptr then
    ctx = api.inttoptr(ptr)
    assert(ptr == api.ptrtoint(ctx)) -- ensure correct convert
  else
    ctx = api.zmq_ctx_new()
    if not ctx then return nil, zerror() end
  end
  local o = {
    _private = {
      owner   = not ptr;
      sockets = make_weak_kv();
      ctx     = ctx;
    }
  }
  return setmetatable(o, self)
end

function Context:closed()
  return not self._private.ctx
end

function Context:destroy()
  if self:closed() then return true end
  for _, skt in pairs(self._private.sockets) do
    skt:close()
  end
  -- lua can remove skt from sockets but do not call finalizer
  -- for skt._private.skt so we enforce gc
  -- collectgarbage("collect")
  -- collectgarbage("collect")

  if self._private.owner then
    api.zmq_ctx_term(self._private.ctx)
  end
  self._private.ctx = nil
  return true
end

Context.term = Context.destroy

function Context:handle()
  return self._private.ctx
end

function Context:get(option)
  assert(not self:closed())
  return api.zmq_ctx_get(self._private.ctx, option)
end

function Context:set(option, value)
  assert(not self:closed())
  local ret = api.zmq_ctx_set(self._private.ctx, option, value)
  if ret == -1 then return nil, zerror() end
  return true
end

function Context:lightuserdata()
  assert(not self:closed())
  local ptr = api.ptrtoint(self._private.ctx)
  assert(self._private.ctx == api.inttoptr(ptr))
  return ptr
end

for optname, optid in pairs(api.CONTEXT_OPTIONS) do
  local name = optname:sub(4):lower()
  Context["get" .. name] = function(self)
    return self:get(optid)
  end

  Context["set" .. name] = function(self, value)
    return self:set(optid, value)
  end
end

function Context:socket(stype)
  assert(not self:closed())
  local skt = api.zmq_socket(self._private.ctx, stype)
  if not skt then return nil, zerror() end
  return setmetatable({
    _private = {
      ctx = self;
      skt = skt;
    }
  },Socket)
end

function Context:autoclose(skt)
  assert(not self:closed())
  assert(self == skt._private.ctx)
  if not skt:closed() then
    self._private.sockets[skt:handle()] = skt
  end
  return true
end

end

do -- Socket
Socket.__index = Socket

function Socket:closed()
  return not self._private.skt
end

function Socket:close()
  if self:closed() then return true end

  if self._private.on_close then
    pcall(self._private.on_close)
  end

  self._private.ctx._private.sockets[ self._private.skt ] = nil

  api.zmq_close(self._private.skt)
  self._private.skt = nil
  return true
end

function Socket:handle()
  return self._private.skt
end

local function gen_skt_bind(bind)
  return function(self, addr)
    assert(not self:closed())
    if type(addr) == 'string' then
      local ret = bind(self._private.skt, addr)
      if -1 == ret then return nil, zerror() end
      return true
    end
    assert(type(addr) == 'table')
    for _, a in ipairs(addr) do
      local ret = bind(self._private.skt, a)
      if -1 == ret then return nil, zerror(), a end
    end
    return true
  end
end

Socket.bind       = gen_skt_bind(api.zmq_bind       )
Socket.unbind     = gen_skt_bind(api.zmq_unbind     )
Socket.connect    = gen_skt_bind(api.zmq_connect    )
Socket.disconnect = gen_skt_bind(api.zmq_disconnect )

function Socket:send(msg, flags)
  assert(not self:closed())
  local ret = api.zmq_send(self._private.skt, msg, flags)
  if ret == -1 then return nil, zerror() end
  return true
end

function Socket:recv(flags)
  assert(not self:closed())
  local msg = api.zmq_msg_init()
  if not msg then return nil, zerror() end
  local ret = api.zmq_msg_recv(msg, self._private.skt)
  if ret == -1 then
    api.zmq_msg_close(msg)
    return nil, zerror()
  end
  local data = api.zmq_msg_get_data(msg)
  local more = api.zmq_msg_more(msg)
  api.zmq_msg_close(msg)
  return data, more ~= 0
end

function Socket:send_all(msg)
  for i = 1, #msg - 1 do
    local str = msg[i]
    local ok, err = self:send(str, FLAGS.ZMQ_SNDMORE)
    if not ok then return nil, err, i end
  end
  local ok, err = self:send(msg[#msg])
  if not ok then return nil, err, #msg end
  return true
end

function Socket:send_more(msg, flags)
  flags = bit.bor(flags or 0, FLAGS.ZMQ_SNDMORE)
  return self:send(msg, flags)
end

function Socket:send_msg(msg, flags)
  return msg:send(self, flags)
end

function Socket:recv_all(flags)
  local res = {}
  while true do
    local data, more = self:recv(flags)
    if not data then return nil, err end
    table.insert(res, data)
    if not more then break end
  end
  return res
end

function Socket:recv_len(len, flags)
  assert(not self:closed())
  assert(type(len) == "number")
  assert(len >= 0)

  local data, len = api.zmq_recv(self._private.skt, len, flags)
  if not data then return nil, zerror() end

  return data, self:more(), len
end

function Socket:recv_msg(msg, flags)
  return msg:recv(self, flags)
end

function Socket:recv_new_msg(flags)
  local msg = Message:new()
  local ok, err = msg:recv(self, flags)
  if not ok then
    msg:close()
    return nil, err
  end
  return msg, err
end

local function gen_getopt(getopt)
  return function(self, option)
    assert(not self:closed())
    local val = getopt(self._private.skt, option)
    if not val then return nil, zerror() end
    return val
  end
end

local function gen_setopt(setopt)
  return function(self, option, value)
    assert(not self:closed())
    local ret = setopt(self._private.skt, option, value)
    if -1 == ret then return nil, zerror() end
    return true
  end
end

Socket.getopt_int = gen_getopt(api.zmq_skt_getopt_int)
Socket.getopt_i64 = gen_getopt(api.zmq_skt_getopt_i64)
Socket.getopt_u64 = gen_getopt(api.zmq_skt_getopt_u64)
Socket.getopt_str = gen_getopt(api.zmq_skt_getopt_str)
Socket.setopt_int = gen_setopt(api.zmq_skt_setopt_int)
Socket.setopt_i64 = gen_setopt(api.zmq_skt_setopt_i64)
Socket.setopt_u64 = gen_setopt(api.zmq_skt_setopt_u64)
Socket.setopt_str = gen_setopt(api.zmq_skt_setopt_str)

function Socket:setopt_str_arr(optname, optval)
  if type(optval) == "string" then
    return self:setopt_str(optname, optval)
  end
  assert(type(optval) == "table")
  for _, str in ipairs(optval) do
    local ok, err = self:setopt_str(optname, str)
    if not ok then return nil, err, str end
  end
  return true
end

for optname, params in pairs(api.SOCKET_OPTIONS) do
  local name    = optname:sub(5):lower()
  local optid   = params[1]
  local getname = "getopt_" .. params[3]
  local setname = "setopt_" .. params[3]
  local get = function(self) return self[getname](self, optid) end
  local set = function(self, value) return self[setname](self, optid, value) end
  if params[2] == "RW" then
    Socket["get_"..name], Socket["set_"..name] = get, set
  elseif params[2] == "RO" then
    Socket[name], Socket["get_"..name] = get, get
  elseif params[2] == "WO" then
    Socket[name], Socket["set_"..name] = set, set
  else
    error("Unknown rw mode: " .. params[2])
  end
end

function Socket:more()
  local more, err = self:rcvmore()
  if not more then return nil, err end
  return more ~= 0
end

function Socket:on_close(fn)
  assert(not self:closed())
  self._private.on_close = fn
  return true
end

end

do -- Message
Message.__index = Message

function Message:new(str_or_len)
  local msg
  if not str_or_len then
    msg = api.zmq_msg_init()
  elseif type(str_or_len) == "number" then
    msg = api.zmq_msg_init_size(str_or_len)
  else
    msg = api.zmq_msg_init_string(str_or_len)
  end
  if not msg then return nil, zerror() end
  return Message:wrap(msg)
end

function Message:wrap(msg)
  return setmetatable({
    _private = {
      msg = ffi.gc(msg, api.zmq_msg_close);
    }
  }, self)
end

function Message:closed()
  return not self._private.msg
end

function Message:close()
  if self:closed() then return true end
  api.zmq_msg_close(ffi.gc(self._private.msg, nil))
  self._private.msg = nil
  return true
end

function Message:handle()
  return self._private.msg
end

local function gen_move(move)
  return function (self, ...)
    assert(not self:closed())
    if select("#", ...) > 0 then assert((...)) end
    local msg = ...
    if not msg then
      msg = move(self._private.msg)
      if not msg then return nil, zerror() end
      msg = Message:wrap(msg)
    elseif getmetatable(msg) == Message then
      if not move(self._private.msg, msg._private.msg) then
        return nil, zerror()
      end
      msg = self
    else
      if not move(self._private.msg, msg) then
        return nil, zerror()
      end
      msg = self
    end
    return msg
  end
end

Message.move = gen_move(api.zmq_msg_move)
Message.copy = gen_move(api.zmq_msg_copy)

function Message:size()
  assert(not self:closed())
  return api.zmq_msg_size(self._private.msg)
end

function Message:set_size(nsize)
  assert(not self:closed())
  local osize = self:size()
  if nsize == osize then return true end
  local msg = api.zmq_msg_init_size(nsize)
  if nsize > osize then nsize = osize end

  ffi.copy(
    api.zmq_msg_data(msg),
    api.zmq_msg_data(self._private.msg),
    nsize
  )

  api.zmq_msg_close(ffi.gc(self._private.msg, nil))
  self._private.msg = ffi.gc(msg, api.zmq_msg_close)
  return true
end

function Message:data()
  assert(not self:closed())
  return api.zmq_msg_get_data(self._private.msg)
end

function Message:set_data(pos, str)
  if not str then str, pos = pos end
  pos = pos or 1
  assert(pos > 0)

  local nsize = pos + #str - 1
  local osize = self:size()
  if nsize <= osize then
    ffi.copy(
      api.zmq_msg_data(self._private.msg, pos - 1),
      str, #str
    )
    return true
  end
  local msg = api.zmq_msg_init_size(nsize)
  if not msg then return nil, zerror() end
  if osize > pos then osize = pos end
  ffi.copy(
    api.zmq_msg_data(msg),
    api.zmq_msg_data(self._private.msg),
    osize
  )
  ffi.copy(api.zmq_msg_data(msg, pos - 1),str)
  api.zmq_close(ffi.gc(self._private.msg, nil))
  self._private.msg = ffi.gc(msg, api.zmq_msg_close)
  return true
end

function Message:send(skt, flags)
  assert(not self:closed())
  if getmetatable(skt) == Socket then
    skt = skt:handle()
  end
  local ret = api.zmq_msg_send(self._private.msg, skt, flags or 0)
  if ret == -1 then return nil, zerror() end
  return true
end

function Message:send_more(skt, flags)
  flags = bit.bor(flags or 0, FLAGS.ZMQ_SNDMORE)
  return self:send(skt, flags)
end

function Message:recv(skt, flags)
  assert(not self:closed())
  if getmetatable(skt) == Socket then
    skt = skt:handle()
  end
  local ret = api.zmq_msg_recv(self._private.msg, skt, flags or 0)
  if ret == -1 then return nil, zerror() end
  local more = api.zmq_msg_more(self._private.msg)
  return self, more ~= 0
end

function Message:more()
  assert(not self:closed())
  return api.zmq_msg_more(self._private.msg) ~= 0
end

function Message:pointer(...)
  assert(not self:closed())
  local ptr = api.zmq_msg_data(self._private.msg, ...)
  -- ptr = ptrtoint(ptr)
  return ptr
end

function Message:set(option, value)
  assert(not self:closed())
  local ret = api.zmq_msg_set(self._private.msg, option, value)
  if ret ~= -1 then return nil, zerror() end
  return true
end

function Message:get(option)
  assert(not self:closed())
  local ret = api.zmq_msg_get(self._private.msg, option)
  if ret ~= -1 then return nil, zerror() end
  return true
end

Message.__tostring = Message.data

end

do -- Poller
Poller.__index = Poller

function Poller:new(n)
  assert((n or 0) >= 0)

  return setmetatable({
    _private = {
      items   = n and ffi.new(api.vla_pollitem_t, n);
      size    = n or 0;
      nitems  = 0;
      sockets = {};
    }
  },self)
end

-- ensure that there n empty items
function Poller:ensure(n)
  local empty = self._private.size - self._private.nitems
  if n <= empty then return true end
  local new = ffi.new(api.vla_pollitem_t, self._private.size + (n - empty))
  if self._private.items then
    ffi.copy(new, self._private.items, ffi.sizeof(api.zmq_pollitem_t) * self._private.nitems)
  end
  self._private.items = new
  return true
end

function Poller:add(skt, events, cb)
  local n = self._private.nitems
  self:ensure(n+1)
  local h
  if type(skt) == "number" then
    self._private.items[n].socket = api.NULL
    self._private.items[n].fd     = skt
    h = skt
  else
    self._private.items[n].socket = skt:handle()
    self._private.items[n].fd     = 0
    h = api.ptrtoint(skt:handle())
  end
  self._private.items[n].events  = events
  self._private.items[n].revents = 0
  self._private.sockets[h] = {skt, cb, n}
  self._private.nitems = n + 1
  return true
end

function Poller:poll(timeout)
  local items, nitems = self._private.items, self._private.nitems
  local ret = api.zmq_poll(items, nitems, timeout)
  if ret == -1 then return nil, zerror() end
  local n = 0
  for i = 0, nitems-1 do
    local item = items[i]
    if item.revents ~= 0 then
      local skt = ptrtoint(item.socket)
      if skt == 0 then skt = item.fd end
      local params = self._private.sockets[skt]
      if params then
        params[2](params[1], item.revents)
      end
      n = n + 1
    end
  end
  return n
end

function Poller:remove(skt)
  local items, nitems, sockets = self._private.items, self._private.nitems, self._private.sockets
  local params = sockets[ptrtoint(skt:handle())]
  if not params  then return true end
  if nitems == 0 then return true end
  local skt_no =  params[3]
  assert(skt_no < nitems)
  
  self._private.nitems = nitems - 1
  nitems = self._private.nitems

  if nitems == 0 then return true end

  local last_item  = items[ nitems ]
  local last_param = sockets[ ptrtoint(last_item.socket) ]

  last_param[3] = skt_no
  items[ skt_no ].socket = last_item.socket
  items[ skt_no ].fd     = last_item.fd
  items[ skt_no ].events = last_item.events

  return true
end

function Poller:start()
  local status, err
  self._private.is_running = true
  while self._private.is_running do
    status, err = self:poll(-1)
    if not status then
      return nil, err
    end
  end
  return true
end

function Poller:stop()
  self._private.is_running = nil
end

end

do -- zmq

function zmq.version()
  local mj,mn,pt = api.zmq_version()
  if mj then return {mj,mn,pt} end
  return nil, zerror()
end

function zmq.context()
  return Context:new()
end

zmq.init = zmq.context

function zmq.init_ctx(ctx)
  return Context:new(ctx)
end

local real_assert = assert
function zmq.assert(...)
  if ... then return ... end
  local err = select(2, ...)
  if getmetatable(err) == Error then error(tostring(err), 2) end
  if type(err) == 'number'      then error(zmq.strerror(err), 2) end
  return error(err or "assertion failed!", 2)
end

function zmq.error(no)
  return Error:new(no)
end

function zmq.strerror(no)
  return string.format("[%s] %s (%d)", 
    api.zmq_mnemoerror(no),
    api.zmq_strerror(no),
    no
  )
end

function zmq.msg_init()          return Message:new()     end

function zmq.msg_init_size(size) return Message:new(size) end

function zmq.msg_init_data(str)  return Message:new(str)  end

for name, value in pairs(api.SOCKET_TYPES)    do zmq[ name:sub(5) ] = value end
for name, value in pairs(api.CONTEXT_OPTIONS) do zmq[ name:sub(5) ] = value end
for name, value in pairs(api.SOCKET_OPTIONS)  do zmq[ name:sub(5) ] = value[1] end
for name, value in pairs(api.FLAGS)           do zmq[ name:sub(5) ] = value end
for name, value in pairs(api.DEVICE)          do zmq[ name:sub(5) ] = value end

zmq.errors = {}
for name, value in pairs(api.ERRORS) do 
  zmq[ name ] = value
  zmq.errors[name]  = value
  zmq.errors[value] = name
end

zmq.poller = {
  new = function(n) return Poller:new(n) end
}

function zmq.device(dtype, frontend, backend)
  local ret = api.zmq_device(dtype, frontend:handle(), backend:handle())
  if ret == -1 then return nil, zerror() end
  return true
end

function zmq.proxy(frontend, backend, capture)
  local ret = api.zmq_proxy(frontend:handle(), backend:handle(), capture:handle())
  if ret == -1 then return nil, zerror() end
  return true
end

end

return zmq
