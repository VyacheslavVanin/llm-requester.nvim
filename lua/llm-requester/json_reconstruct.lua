local json_processor = {}

local buffer = ""

function json_processor.process_part(chunk, callback)
    if buffer == "" then
        -- FIXME: decoding two times :(
        local success, decoded = pcall(vim.json.decode, chunk)
        if success then
            callback(chunk)
            return
        end

        buffer = buffer .. chunk
        return
    end

    buffer = buffer .. chunk
    -- FIXME: decoding two times :(
    local success, decoded = pcall(vim.json.decode, buffer)
    if success then
        callback(buffer)
        buffer = ""
        return
    end
end

function json_processor.finalize(callback)
    if #buffer > 0 then
        callback(buffer)
        buffer = ""
    end
end

function json_processor.get_buffer()
    return buffer
end

return json_processor