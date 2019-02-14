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

generates addition code into `Dst` param.

## dasm.lua (by luapower)

The highest level API.

- Initialize JIT
- Collect machine code from generators
- Link result code (resolve label addr)


# x64 NOP function generator

Generators

``` lua
local ffi = require('ffi') -- required
local dasm = require('dasm') --required

--must be the first instruction
|.arch x64
--make an action list called `actions`
|.actionlist actions
|.globalnames globalnames

local gen = {}

function gen.nop(Dst)
        |nop
end

function gen.int3(Dst)
        |int3
end

function gen.prolog(Dst)
        |push rbp
        |mov rbp,rsp
end

function gen.epilog(Dst)
        |mov rsp, rbp
        |pop rbp
        |ret
end

return {gen = gen, actions = actions, globalnames = globalnames}
```

Compiler/Linker and Exec

```
local ffi = require('ffi')
local dasm = require('dasm')
local dynasm = require('dynasm')

-- load generators
local lisp_x64 = dynasm.loadfile(script_dir..'/'..'x64.dasl')()

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

# Parser

Just translate text to tree.
It is easy to iterate over text in lua.

It is really helpful to add metainformation using metatables.

# Interesting in asm

- no operator between mem and mem
- integer division use hard-coded registers
- shl,shr uses hard-coded register or constant

- 2006 year links is still actual:)


# References

LuaJIT

* Home - https://luajit.org/dynasm.html
* Tutorial - https://corsix.github.io/dynasm-doc/
* Lua Tutorial - https://github.com/luapower/dynasm/blob/master/dynasm.md

Asm

* x86-64 example - http://nickdesaulniers.github.io/blog/2014/04/18/lets-write-some-x86-64/

* calling conventions - https://www.agner.org/optimize/calling_conventions.pdf

* references - https://www.felixcloutier.com/x86/index.html
