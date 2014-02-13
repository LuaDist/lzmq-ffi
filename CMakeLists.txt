cmake_minimum_required ( VERSION 2.8 )

project ( lzmq-ffi C )
include ( cmake/dist.cmake )
include ( lua )

include_directories ( ${CMAKE_CURRENT_SOURCE_DIR}/src )

set ( LZTIMER_SRC src/ztimer.c src/lzutils.c )

install_lua_module ( lzmq              src/lua/lzmq/ffi/lzmq.lua     )
install_lua_module ( lzmq.ffi          src/lua/lzmq/ffi.lua          )
install_lua_module ( lzmq.loop         src/lua/lzmq/loop.lua         )
install_lua_module ( lzmq.poller       src/lua/lzmq/ffi/poller.lua   )
install_lua_module ( lzmq.threads      src/lua/lzmq/threads.lua      )
install_lua_module ( lzmq.ffi.api      src/lua/lzmq/ffi/api.lua      )
install_lua_module ( lzmq.ffi.error    src/lua/lzmq/ffi/error.lua    )
install_lua_module ( lzmq.llthreads.ex src/lua/lzmq/llthreads/ex.lua )
install_lua_module ( lzmq.impl.threads src/lua/lzmq/impl/threads.lua )
install_lua_module ( lzmq.impl.loop    src/lua/lzmq/impl/loop.lua    )

if(UNIX AND NOT APPLE)
  set ( RT_LIBRARY rt )
else()
  set ( RT_LIBRARY )
endif()

install_lua_module ( lzmq.timer ${LZTIMER_SRC} LINK ${RT_LIBRARY} )

install_data ( README.md LICENCE.txt )

install_example ( examples/ )

install_test ( test/ examples/utils.lua )
