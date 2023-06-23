module AIChatREPL

using DotEnv, HTTP, JSON3, OpenAI, ProgressMeter
using REPL: REPL, LineEdit

abstract type APIModel end
function _parse_lines end
function chat_on_done end
const OPENAI_API_KEY = Ref{String}()
function tryrequest_with_spinner end

include("TextDavinci003.jl")

const MODEL_ID_CANDIDATES = [
    "gpt4-0613",
    "gpt4-0314",
    "gpt4",
    "gpt-3.5-turbo-0613",
    "gpt-3.5-turbo-0301",
    "gpt-3.5-turbo",
    "text-davinci-003"
]

const MODEL_ID_CHANNEL = Channel{String}(1)
function fetch_model_id()
    @assert isassigned(OPENAI_API_KEY) "OpenAI API Key is NOT set. "
    fetch(MODEL_ID_CHANNEL)
end
# const MODEL_ID = Ref{String}()

struct ChatAPIModel <: APIModel
    name::String
end
struct StreamChatAPIModel <: APIModel
    name::String
end
APIModel(name::AbstractString) = APIModel(Val(Symbol(name)), name)
@generated function APIModel(::Val, name::AbstractString)
    if isdefined(OpenAI, :request_body_live)
        :(StreamChatAPIModel(String(name)))
    else
        :(ChatAPIModel(String(name)))
    end
end
Base.string(model::APIModel) = model.name

get_model() = APIModel(fetch_model_id())

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

function _parse_lines(model::APIModel, lines::AbstractString, filename)
    matches = match(r".*?^```julia.*?\n(.*?)^```\n(.*)"ms, lines)
    isnothing(matches) && return nothing
    ex = Expr(:toplevel)
    # ```julia ～ ``` 内をparse
    ex_tmp = _parse_lines_sub(matches[1], filename)
    if ex_tmp isa Expr && (ex_tmp.head === :toplevel || ex_tmp.head === :block)
        append!(ex.args, ex_tmp.args)
    else
        push!(ex.args, ex_tmp)
    end
    # 後ろを再帰的にparse
    ex_tmp = _parse_lines(model, matches[2], filename)
    if ex_tmp isa Expr && (ex_tmp.head === :toplevel || ex_tmp.head === :block)
        append!(ex.args, ex_tmp.args)
    else
        push!(ex.args, ex_tmp)
    end
    ex
end

function _parse_lines_sub(lines::AbstractString, filename)
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
            for (index, line) in pairs(ex.args)
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

# chat_on_done(line, repl) = chat_on_done(get_model(), line)
function chat_on_done(model::ChatAPIModel, repl, hp, line)
    r = tryrequest_with_spinner() do
        create_chat(
            OPENAI_API_KEY[],
            fetch_model_id(),
            [Dict("role"=>"user", "content"=>line)],
        )
    end
    contents = [choice["message"]["content"] for choice in r.response["choices"]]
    # text = join(contents, '\n')
    text = contents[begin]  # 最初温1件だけ持ってくればOK
    # output
    println(REPL.outstream(repl), text)
    # parse
    _parse_lines(model, text, REPL.repl_filename(repl, hp))
end

function chat_on_done(model::StreamChatAPIModel, repl, hp, line)
    repl_out = REPL.outstream(repl)
    contents = sprint() do io
        create_chat(
            OPENAI_API_KEY[],
            string(model),
            [Dict("role"=>"user", "content"=>line)];
            streamcallback=let
                function (chunk)
                    for line in split(chunk, '\n')
                        line = strip(line)
                        isempty(line) && continue
                        if line != "data: [DONE]"
                            chunk_obj = JSON3.read(line[6:end])
                            delta = chunk_obj.choices[1].delta
                            if haskey(delta, :content)
                                print(repl_out, delta.content)
                                print(io, delta.content)
                            end
                        end
                    end
                end
            end
        )
    end
    println(repl_out)  # 最後に改行を出力
    _parse_lines(model, contents, REPL.repl_filename(repl, hp))
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
        chat_on_done(get_model(), repl, hp, line)
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
    @async begin
        res = OpenAI.list_models(OPENAI_API_KEY[])
        available_model_ids = [model["id"] for model in res.response["data"]]
        model_id_index = findfirst(∈(available_model_ids), MODEL_ID_CANDIDATES)
        put!(MODEL_ID_CHANNEL, MODEL_ID_CANDIDATES[model_id_index !== nothing ? model_id_index : end])
    end

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
