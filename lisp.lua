#!/usr/bin/env tarantool

local utf8 = require('utf8')


local function parse(input, ast)
    local WAIT_ANY = 1
    local WAIT_DOUBLE_QUOTE = 2
    local state = WAIT_ANY

    local ast = {}
    local stack = {}

    local skip = false

    local capture_start = nil
    local capture = {}

    local list_start = nil
    for position, codepoint in utf8.next, input do
        if not skip then
        if state == WAIT_ANY then
            if codepoint == string.byte('\n')
                or codepoint == string.byte('\r')
                or codepoint == string.byte(' ')
            or codepoint == string.byte('\t') then

                if #capture > 0 then
                    table.insert(ast, {atom = table.concat(capture),
                                       position=capture_start})
                    capture = {}
                    capture_start = nil
                end

            elseif codepoint == string.byte('(') then
                if #capture > 0 then
                    table.insert(ast, {atom = table.concat(capture),
                                       position=capture_start})
                    capture = {}
                    capture_start = nil
                end

                local inner = setmetatable({}, {position=position})
                table.insert(ast, inner)

                table.insert(stack, ast)
                ast = inner

            elseif codepoint == string.byte(')') then
                if #capture > 0 then
                    table.insert(ast, {atom = table.concat(capture),
                                       position=capture_start})
                    capture = {}
                    capture_start = nil
                end

                if #stack <= 0 then
                    error('Unexpected end of list')
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
                position, codepoint = utf8.next(input, position)
                skip = true
                if position == nil then
                    -- TODO error
                    error('Unexpected eof')
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
                    error('Wrong escaping')
                end
            elseif codepoint == string.byte('"') then
                table.insert(ast, {atom = table.concat(capture),
                                   position=capture_start})
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
        table.insert(ast, {atom = table.concat(capture),
                           position=capture_start})
        capture = {}
        capture_start = nil
    end

    if #stack >= 1 then
        error('List is not closed')
    end

    return ast
end

return {
    parse=parse
}
