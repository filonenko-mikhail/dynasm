#!/usr/bin/env tarantool
local fio = require('fio')
local script_dir = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or './'
script_dir = fio.abspath(script_dir)
package.path = package.path .. ';' .. script_dir .. '/?.lua'

local ffi = require('ffi')
local dasm = require('dasm')
local dynasm = require('dynasm')

-- load generators
local x64 = dynasm.loadfile(script_dir..'/'..'x64.dasl')()

-- make compiler state from generators
local state, globals = dasm.new(x64.actions)

-- generate code
x64.gen.prolog(state)
x64.gen.nop(state)
x64.gen.epilog(state)

--check, link and encode the code
local buf, size = state:build()

local JIT = {}
JIT.buf = buf

-- DEBUG functionality
local dump = {}
local function capture_dump(line)
    table.insert(dump, line)
end
dasm.dump(buf, size, capture_dump)
JIT.disasm = table.concat(dump)

local callable = ffi.cast('void __cdecl (*) ()', JIT.buf)
callable()
