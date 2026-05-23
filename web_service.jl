using Sockets

function find_available_port(start_port::Integer; tries::Integer = 100)::Int
    for i in 0:tries-1
        try
            s = Sockets.listen(Sockets.IPv4("127.0.0.1"), start_port + i)
            close(s)
            return start_port + i
        catch
        end
    end
    error("No available port from $(start_port) to $(start_port + tries).")
end

function open_browser(url::AbstractString)
    cmds = if Sys.iswindows()
        # PowerShell 7, then Windows PowerShell 5.1, then cmd.
        [`pwsh -NoProfile -Command "Start-Process \"$url\""`,
         `powershell -NoProfile -Command "Start-Process \"$url\""`,
         `cmd /c start "" $url`]
    elseif Sys.isapple()
        [`open $url`]
    else
        [`xdg-open $url`]
    end
    for cmd in cmds
        try
            run(cmd; wait = false)
            return
        catch
        end
    end
    @warn "Failed to open $url in browser."
end
