# DynASM

Всем привет. Меня зовут Миша Филоненко. Я из Беларуси. I work at tarantooll
solutions team. We adopt tarantool for customer cases.

Сегодня я хочу поговорить о тулсете DynASM сделанным Майком Полом
и слегка модифицированном Cosmin A. (Apreutesei) from Bucharest.

DynASM является инструментом для динамической генерации кода.
Он создавался для LuaJIT, но его можно использовать и отдельно для своих нужд.

Цель доклада - введение в тулсет DynASM и построение простейшего компилятора.

Я хочу рассмотреть компилятор пользовательских запросов.
А именно простейшего компилируемого языка запросов в БД (Тарантул).

# Motivation

Зачем нужен отдельный язык запросов и его компилятор?

Представим что есть база данных.

В простых случаях использования сервис предоставляет
простой интерейс типа

``` lua
server.insert_info(primary_key, info)
```
и
``` lua
server.update_info(primary_key, newinfo)

server.get_info(primary_key)
```

Однако в случае запроса данных по нескольким критериям все становится сложнее.

В самых сложных случаях данные обрабатываются на клиенте вручную.

``` lua
local resultset = {}
for tuple in server.list_info() do
  if tuple matches critries then
    table.insert(resultset, tuple)
  end
end
```

Оптимальнее перенести такой цикл поиска необходимой информации
на сервер.

``` lua
server.execute(Quey)
```

И сервер исполнит наш запрос в таком виде в котором посчитает нужным
и передаст нам только интересующую часть данных.

Собственно это архитектура SQL серверов придуманная много лет назад.

# Architecture

Схема происходящего выглядит так

```
User query    conversion to instructions of      intel/amd CPU
   (A)  ---------------------------------------  (B)
                        ^
                        |
        we are here trying to make compiler
        with
          - parser/lexer
          - ast
          -
          - instruction generation
          - instruction linking
       using
          - DynASM
          - x86 and amd64 instruction reference
          - lldb
          - stcall calling conventions
```


Компилятор будет состоять из частей
 - парсер пользовательского запроса
 - преобразователь в high level AST
 - преобразователь в low level AST
 - компилятор AST low level в инструкции процессора

# Parser

Я выбрал самый простой вариант языка который базируется на s-выражениях.

Такой язык содержит в себе две сущности
 - атом
 - список

Список включает в себя атомы и другие списки

Например:

`12` - атом
`"Hello world"` - aтом
`+` - атом

`(do-nothing)` - список из одного атома `do-nothing`
`(+ 1 2)` - список из трех атомов: `+`, `1` и `2`

`(- 3 (+ 1 2))` - список из атомов `-`, `3` и другого списка,
который в свою очередь состоит из трех атомов `+`, `1`, `2`.

Парсер просто преобразует строку в луа таблицу

``` lua
parse("(- 3 (+ 1 2))")
=>
{'-', '3', {'+', '1', '2'}}
```

На этом этапе мы
 - разбираем строку
 - валидируем синтаксис
 - сохраняем метаинформацию о позициях списков и символов в строке

# Conversion to AST

AST - это дерево
  - узел - действия которые надо произвести
  - ветки узла - это аргументы для действия

Например

```
- '+'
    ` '1'
    ` '2'
```

Синтаксис s-выражений как есть ложится в AST по правилу

- первый элемент списка является действием
- остальные являются аргументами к действию

Дерево для простейшего запроса будет выглядеть так

```
- '-'
    ` '3'
    ` '+'
        ` '1'
        ` '2'
```


На этом этапе
- мы валидируем семантику

# AST transformation

В случаях когда язык для пользователя позволяет оперировать высокоуровневыми
конструкциям а компилятор умеет компилировать низкоуровневые мы преобразовываем
пользовательское AST к AST которое компилятор сможет скомпилировать

Например обычно пользователь оперирует операцией сложения
с произвольным количеством аргументов, в то время как компилятор
может генерировать операцию сложения только для двух аргументов.

Так high level AST

- '+'
    ` '1'
    ` '2'
    ` '3'
    ` '4'

преобразуется к виду

- '+'
    ` '+'
        ` '1'
        ` '+'
            ` '2'
            ` '+'
                ` '3'
                ` '4'

Так low level AST уже может быть скомпилировано в инструкции процессора

# AST compiler

Компилятор проходит по дереву и генерирует код который его исполнит.

Я использовал стековый компилятор, как самый простой.

У него простой принцип, все аргументы функции пушаются в стек
и результат функции после работы остается на вершине стека.

Атомы пушаются в стек как есть

Например

```
- '+'
    ` '1'
    ` '2'
```

Компилятор преобразует в наивные инструкции

``` asm
push 1 to stack
push 2 to stack

add stack[1] and stack[2]
pop all arguments
push result
```

# DynASM

Настало время скомпилировать low-level AST с помощью DynASM

DynASM тулсет состоит из нескольких частей

- core - libdasm.dylib
- ffi binding to core - dasm.lua
- code processor - dynasm.lua

Наши действия

Спроектировать генераторы asm инструкций
Организовать итоговую генерацию, линковку и вызов

Отдельный файл asm инструкций необходим для каждой платформы и операционной системы. Я рассмотрю только amd64 (или x64, x86_64) macos платформу.

# DynASM asm code generators

In simplified form without control directives code generator function is
mixed lua and asm code


``` lua
-- x64.dasl
... -- control directives and structures

function nop(destination)
        |nop
end

...
```

 - Assembler code is separated from lua code by vertical line
 - Assembler code is not inline

so when you call `nop(destination)` function generate `nop` instruction
into destination.
`nop` do nothing so we can safely generate it at any place.

The next step is to use build result code using code generators and call it

# DynASM code builder

``` lua
-- load generators
local x64 = dynasm.loadfile('x64.dasl')()

-- make compiler state from generators
local state, globals = dasm.new(x64.actions)
x64.nop(state)
local buf, size = state:build()

local callable = ffi.cast('void __cdecl (*) ()', buf)
callable()
```

This code is broken. The question is why?



# DynASM


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

- amount of intel mnemonics (e.g., add, mov, idiv, etc) 981
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
* count x86 asm - https://stefanheule.com/blog/how-many-x86-64-instructions-are-there-anyway/



 - Чето коротко
 - Лучше суровое советское произошение
 - Очень много кода - нужны объяснения
 - Ассемблерные нопы - загадка
 - Стоит добавить поясняющих слайдов
  - Что например будет в следующем слайде
 - Волнения меньше - скачет мысль - лучше медленее
 - С кусками кода нужно что-то делать
 - Детали о чем доклад
 - Как появился Лисп
 - Вторым слайдом подтезисы - более детальное описание
 - Как придти к dsl языку
 - Кратенькую подсказку по английским тезисам
