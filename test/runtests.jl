module AIChatREPLTest

Base.ENV["OPENAI_API_KEY"] = ""  # DUMMY

using AIChatREPL
using Test

@testset "AIChatREPL.jl" begin
    # @test AIChatREPL.OPENAI_API_KEY[] == ""
    @test isassigned(AIChatREPL.OPENAI_API_KEY)
end

end