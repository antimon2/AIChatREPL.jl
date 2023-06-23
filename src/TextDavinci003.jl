module TextDavinci003

import ..AIChatREPL: APIModel, chat_on_done, _parse_lines
using ..AIChatREPL: OPENAI_API_KEY, tryrequest_with_spinner
using OpenAI, REPL

const MODEL_ID = "text-davinci-003"

struct TextDavinciAPIModel <: APIModel
    name::String
end

function APIModel(::Val{Symbol("text-davinci-003")}, name::AbstractString)
    TextDavinciAPIModel(name)
end

function chat_on_done(model::TextDavinciAPIModel, repl, hp, line)
    temperature=0  # Randomness Control [0-1]
    max_tokens=1000  # Maximum number of returned response tokens
    top_p=1.0  # Controlling Diversity [0-1]
    frequency_penalty=0.0  # Frequency Control [0-2]: Higher value makes it not to be repeat the same topics.
    presence_penalty=0.0  # New Topic Control [0-2]: High value makes it easier for new topics to emerge.
    r = tryrequest_with_spinner() do
        create_completion(
            OPENAI_API_KEY[],
            string(model);
            prompt=line,
            temperature,  # Randomness Control [0-1]
            max_tokens,  # Maximum number of returned response tokens
            top_p,  # Controlling Diversity [0-1]
            frequency_penalty,  # Frequency Control [0-2]: Higher value makes it not to be repeat the same topics.
            presence_penalty,  # New Topic Control [0-2]: High value makes it easier for new topics to emerge.
        )
    end
    contents = [choice["text"] for choice in r.response["choices"]]
    text = join(contents, "\n")
    # output
    println(REPL.outstream(repl), text)
    # parse
    _parse_lines(model, text, REPL.repl_filename(repl, hp))
end

function _parse_lines(model::TextDavinciAPIModel, lines::AbstractString, filename)
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
                elseif line isa Expr && line.head === :macrocall && (
                        line.args[1] === Symbol("@cmd") || line.args[1] isa GlobalRef && line.args[1].name === Symbol("@cmd")
                    )
                    if startswith(line.args[end], r"julia.*?\n")
                        # ```julia ～ ``` で括られたマークダウン形式のJuliaコード→その文字列部分（2行目以降）を再parseする
                        # ex = Meta.parseall(split(ex.args[end], "\n", limit=2)[end], filename=filename)
                        sub_ex = _parse_lines(model, split(line.args[end], "\n", limit=2)[end], filename)
                        ex.args[index] = sub_ex.args[end]  # sub_ex が :toplevel の Expr になってるはずなので
                        # haserror = true
                        # break
                    else
                        # その他の ```～``` で括られたマークダウン形式の文字列→無視
                        ex.args[index] = nothing
                    end
                end
            end
        end
        haserror || break
        ex = Meta.parseall(s, filename=filename)
    end
    return ex
end

end