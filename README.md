# Intro

All things we speak is about us.
The languages which we made is for other people.

# Core library (libdasm)

Contains machine code generator and linker.

## Core initialization

- `dasm_init`
- `dasm_setupglobal`
- `dasm_setup`

## Core code generation

- `dasm_put` to generate code
- `dasm_checkstep` to validate some cases
- `dasm_growpc` to increase max count of labels

## Core finalization

- `dasm_link`
- `dasm_encode`

`call` code from beginning
or
`call` certain region of code using `dasm_getpclabel`

Free resources
- `dasm_free`

# Lua Dynasm Tool

## dynasm.lua (patched luapower)

- translate, compile and run Lua/ASM code from Lua (no C glue)
- load Lua/ASM (.dasl) files with require()
- works with file, string and stream inputs and outputs

### Lua/ASM code

It's mix of lua code and assembler

For e.g.

``` lua
function generate_add(Dst)
    | add rax, rbx
end
```

## dasm.lua (by luapower)

The highest level API.

- Initialize JIT
- Collect machine code from generators
- Links result code with external symbols


# x64 NOP function generator

Generators

``` lua

```

Compiler/Linker and Exec

```
-- load generators
local lisp_x64 = dynasm.loadfile('lisp_x64.dasl')()

-- make compiler state from generators
local state, globals = dasm.new(lisp_x64.actions)

-- generate code
lisp_x64.gen.prolog(state)
lisp_x64.gen.nop(state)
lisp_x64.gen.epilog(state)

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
```

# References

* https://luajit.org/dynasm.html

* https://corsix.github.io/dynasm-doc/

* https://github.com/luapower/dynasm/blob/master/dynasm.md
