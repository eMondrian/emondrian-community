-- Error-log messages without the request line. ngx.log inside a request appends it (so does
-- ngx.errlog's raw_log), and on /xmla?emondrian_token=… that line holds a personal token
-- (link.lua). A zero-delay timer runs outside the request, so its message goes alone.

local M = {}

function M.out_of_request(level, message)
  -- Without a timer (the worker is shutting down) the message is dropped rather than written
  -- with the request line
  ngx.timer.at(0, function() ngx.log(level, message) end)
end

return M
