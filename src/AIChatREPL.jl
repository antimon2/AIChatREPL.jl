module AIChatREPL

using DotEnv, HTTP, OpenAI, ProgressMeter
using REPL: REPL, LineEdit

const MODEL_ID = "text-davinci-003"

const OPENAI_API_KEY = Ref{String}()

# tryrequest(fn::Function, args...; retry::Int = 3, kwargs...) = _tryrequest_w_retrytimes(fn, retry, args, kwargs)
function _tryrequest_w_retrytimes(fn, retrytimes::Int, args, kwargs)
    retrytimes < 1 && (retrytimes = typemax(Int))
    for retry_count = 1:retrytimes-1
        try
            return fn(args...; kwargs...)
        catch ex
            if ex isa HTTP.IOExtras.IOError && occursin(r"during request.+?openai", ex.message)
                @warn "Retry" ex retry_count
            else
                # @show ex
                # dump(ex)
                rethrow(ex)
            end
        end
    end
    fn(args...; kwargs...)  # when an error/exception raised, throw it as is.
end

function tryrequest_with_spinner(fn::Function, args...; retry::Int = 3, kwargs...)
    prog = ProgressUnknown("loading...", spinner=true);
    ProgressMeter.next!(prog)
    # t = @async tryrequest(fn, args...; retry, kwargs...)
    t = @async _tryrequest_w_retrytimes(fn, retry, args, kwargs)
    while !istaskdone(t) && !istaskfailed(t)
        ProgressMeter.next!(prog)
        yield()
    end
    failed = istaskfailed(t)
    ProgressMeter.finish!(prog, spinner=(failed ? '✗' : '✓'))
    fetch(t)
end

function _parse_lines(lines::AbstractString, filename)
    ex = Meta.parseall(lines, filename=filename)
    s = String(lines)
    @debug "try" s
    while true
        haserror = false
        if ex isa Expr && ex.head === :toplevel
            if isempty(ex.args)
                return nothing
            end
            # last = ex.args[end]
            lineno = 1
            for line in ex.args
                if line isa LineNumberNode
                    lineno = line.line
                elseif line isa Expr && (line.head === :error || line.head === :incomplete)
                    # to determine whether these errors seems to be that input is just a natural sentence (and not a valid Julia code)
                    m = match(r"(extra token|invalid character)\s+\"(.+?)\"", line.args[1])
                    if !isnothing(m)
                        if m[1] != "invalid character" || all(ispunct(c) for c in m[2])
                            # the parse error is due to a sequence of words (separated by spaces) or the presence of a symbolic character (punctuation)
                            # → the line is considered to be a simple natural sentence and is commented out
                            if lineno ≤ 1
                                s = "# " * s  # Just prepend "# "
                            else
                                rex = Regex(raw"((?:[^\n]*?\n){" * string(lineno-1) * raw",}?)([^\n]*?" * m[2] * ")")
                                s = replace(s, rex=>s"\1# \2")
                            end
                            @debug "retry" s
                            haserror = true
                            break
                        end
                    end
                    # Any other parse error is returned as-is (no input is evaluated).
                    return line
                end
            end
        end
        haserror || break
        ex = Meta.parseall(s, filename=filename)
    end
    return ex
end

function create_mode(repl, main_mode)
    chat_mode = LineEdit.Prompt("chat> ";
        prompt_prefix = Base.text_colors[:cyan],
        prompt_suffix = "",
        # complete = nothing,
        sticky = true)
    chat_mode.repl = repl
    hp = main_mode.hist
    hp.mode_mapping[:chat] = chat_mode
    chat_mode.hist = hp

    _search_prompt, skeymap = LineEdit.setup_search_keymap(hp)
    _prefix_prompt, prefix_keymap = LineEdit.setup_prefix_keymap(hp, chat_mode)

    chat_mode.on_done = REPL.respond(repl, main_mode) do line
        # r = tryrequest() do
        r = tryrequest_with_spinner() do
            create_completion(
                OPENAI_API_KEY[],
                MODEL_ID;
                prompt=line,
                temperature=0,  # Randomness Control [0-1]
                max_tokens=1000,  # Maximum number of returned response tokens
                top_p=1.0,  # Controlling Diversity [0-1]
                frequency_penalty=0.0,  # Frequency Control [0-2]: Higher value makes it not to be repeat the same topics.
                presence_penalty=0.0,  # New Topic Control [0-2]: High value makes it easier for new topics to emerge.
            )
        end
        text = join([choice["text"] for choice in r.response["choices"]], '\n')
        # output
        println(REPL.outstream(repl), text)
        # parse
        _parse_lines(text, REPL.repl_filename(repl, hp))
    end

    mk = REPL.mode_keymap(main_mode)

    b = Dict{Any, Any}[
        skeymap, #=repl_keymap,=# mk, prefix_keymap, LineEdit.history_keymap,
        LineEdit.default_keymap, LineEdit.escape_defaults
    ]
    chat_mode.keymap_dict = LineEdit.keymap(b)
    return chat_mode
end

function repl_init(repl)
    main_mode = repl.interface.modes[1]
    chat_mode = create_mode(repl, main_mode)
    push!(repl.interface.modes, chat_mode)
    org_action = main_mode.keymap_dict['\x07']  # Ctrl+G
    keymap = Dict{Any, Any}(
        '\x07' => function (s, args...)
            if isempty(s) || position(LineEdit.buffer(s)) == 0
                buf = copy(LineEdit.buffer(s))
                LineEdit.transition(s, chat_mode) do
                    LineEdit.state(s, chat_mode).input_buffer = buf
                end
            else
                org_action(s, args...)
            end
        end
    )
    main_mode.keymap_dict = LineEdit.keymap_merge(main_mode.keymap_dict, keymap)
    return
end

function __init__()
    key="OPENAI_API_KEY"
    _ENV = DotEnv.config(override=true)  # load "/.env" file, override `ENV`
    @assert (haskey(_ENV.dict, key) || haskey(Base.ENV, key)) "Set the environment variable `OPENAI_API_KEY`."
    OPENAI_API_KEY[] = haskey(_ENV.dict, key) ? _ENV.dict[key] : ENV[key]

    if isdefined(Base, :active_repl)
        repl_init(Base.active_repl)
    else
        atreplinit() do repl
            if isinteractive() && repl isa REPL.LineEditREPL
                isdefined(repl, :interface) || (repl.interface = REPL.setup_interface(repl))
                repl_init(repl)
            end
        end
    end
end

end
