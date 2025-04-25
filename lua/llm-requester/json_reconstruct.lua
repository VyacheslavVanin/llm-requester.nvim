local json_processor = {}

local buffer = ""

function json_processor.process_part(chunk, callback)
    if buffer == "" then
        local success, decoded = pcall(vim.json.decode, chunk)
        if success then
            callback(decoded)
            return
        end

        buffer = buffer .. chunk
        return
    end

    buffer = buffer .. chunk
    local success, decoded = pcall(vim.json.decode, buffer)
    if success then
        callback(decoded)
        buffer = ""
        return
    end
end

function json_processor.finalize(callback)
    if #buffer > 0 then
        local success, decoded = pcall(vim.json.decode, buffer)
        if success then
            callback(buffer)
            buffer = ""
        end
    end
end

function json_processor.get_buffer()
    return buffer
end

return json_processor
