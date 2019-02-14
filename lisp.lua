#!/usr/bin/env tarantool


local utf8 = require('utf8')

local utils = require('lisp_utils')


local function parse(input, ast)
    local WAIT_ANY = 1
    local WAIT_DOUBLE_QUOTE = 2
    local state = WAIT_ANY

    local ast = setmetatable({}, {__index={position=0}})
    local stack = {}

    local skip = false

    local capture_start = nil
    local capture = {}

    for position, codepoint in utf8.next, input do
        if not skip then
            if state == WAIT_ANY then
                if codepoint == string.byte('\n')
                    or codepoint == string.byte('\r')
                    or codepoint == string.byte(' ')
                or codepoint == string.byte('\t') then

                    if #capture > 0 then
                        table.insert(ast,
                                     setmetatable({atom = table.concat(capture)},
                                         {__index={position=capture_start}}))
                        capture = {}
                        capture_start = nil
                    end

                elseif codepoint == string.byte('(') then
                    if #capture > 0 then
                        table.insert(ast, setmetatable({atom = table.concat(capture)},
                                         {__index={position=capture_start}}))
                        capture = {}
                        capture_start = nil
                    end

                    local inner = setmetatable({}, {__index={position=position}})
                    table.insert(ast, inner)

                    table.insert(stack, ast)
                    ast = inner

                elseif codepoint == string.byte(')') then
                    if #capture > 0 then
                        table.insert(ast, setmetatable({atom = table.concat(capture)},
                                         {__index={position=capture_start}}))
                        capture = {}
                        capture_start = nil
                    end

                    if #stack <= 0 then
                        return nil, 'Unexpected end of list at position %q'
                    end

                    ast = stack[#stack]
                    stack[#stack] = nil
                else
                    if codepoint == string.byte('"') then
                        state = WAIT_DOUBLE_QUOTE
                    else
                        table.insert(capture, utf8.char(codepoint))
                        capture_start = capture_start or position
                    end
                end
            elseif state == WAIT_DOUBLE_QUOTE then
                if codepoint == string.byte('\\') then
                    local oldposition = position
                    position, codepoint = utf8.next(input, position)
                    skip = true
                    if position == nil then
                        -- TODO error
                        utils.errorx('Unexpected eof')
                    end
                    if codepoint == string.byte('r') then
                        table.insert(capture, '\r')
                        capture_start = capture_start or position
                    elseif codepoint == string.byte('n') then
                        table.insert(capture, '\n')
                        capture_start = capture_start or position
                    elseif codepoint == string.byte('t') then
                        table.insert(capture, '\t')
                        capture_start = capture_start or position
                    elseif codepoint == string.byte('"') then
                        table.insert(capture, utf8.char(codepoint))
                        capture_start = capture_start or position
                    elseif codepoint == string.byte('\\') then
                        table.insert(capture, utf8.char(codepoint))
                        capture_start = capture_start or position
                    else
                        utils.errorx('Wrong escaping at position %q', oldposition)
                    end
                elseif codepoint == string.byte('"') then
                    table.insert(ast, setmetatable({atom = table.concat(capture)},
                                     {__index={position=capture_start}}))
                    capture = {}
                    capture_start = nil

                    state = WAIT_ANY
                else
                    table.insert(capture, string.char(codepoint))
                    capture_start = capture_start or position
                end
            end
        else
            skip = false
        end
    end

    if #capture > 0 then
        table.insert(ast, setmetatable({atom = table.concat(capture)},
                         {__index={position=capture_start}}))
        capture = {}
        capture_start = nil
    end

    if #stack >= 1 then
        utils.errorx('List is not closed')
    end

    return ast
end

return {
    parse=parse
}
