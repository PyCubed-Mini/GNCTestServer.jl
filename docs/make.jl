# Inside make.jl
push!(LOAD_PATH, "../src/")
using Simulator
using Documenter
makedocs(
    sitename="GNCTestServer.jl",
    modules=[Simulator],
    pages=[
        "Home" => "index.md"
    ])
deploydocs(;
    repo="https://github.com/PyCubed-Mini/GNCTestServer"
)