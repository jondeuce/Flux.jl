loadleaf!(dst, src) = dst
loadleaf!(dst::AbstractArray, src) =
  error("Tried to copy $src into an array destination; this is not allowed.")
loadleaf!(dst, src::AbstractArray) =
  error("Tried to copy an array to $dst; this is not allowed.")

function loadleaf!(dst::AbstractArray, src::Bool)
  if iszero(src)
    dst .= src
  else
    error("Cannot copy boolean parameter == true to non-zero parameter.")
  end
  return dst
end

loadleaf!(dst::Bool, src::AbstractArray) = iszero(dst) ? dst :
  error("Cannot copy non-zero parameter to boolean parameter == true.")

function loadleaf!(dst::AbstractArray, src::AbstractArray)
  err = DimensionMismatch("Tried to load size $(size(src)) array into size $(size(dst))")
  (size(dst) == size(src)) || throw(err)
  copyto!(dst, src)
end

_tie_check(dst::Bool, src::AbstractArray) = iszero(dst) ||
  error("Encountered tied parameter with boolean source at some nodes and non-boolean sources at others.")
_tie_check(dst::AbstractArray, src::Bool) = (iszero(dst) && iszero(src)) ||
  error("Encountered tied parameter with boolean source at some nodes and non-boolean sources at others.")
_tie_check(dst::AbstractArray, src::AbstractArray) = (dst == src) ||
  error("Encountered tied destination parameters with untied and mismatched sources.")
_tie_check(dst, src) = true

_bool_tie_check(dst, src) = true

_filter_children(f, children::NamedTuple) =
  NamedTuple(filter(kv -> f(kv[2]), pairs(children)))
_filter_children(f, children) = filter(f, children)

"""
    loadmodel!(dst, src)

Copy all the parameters (trainable and non-trainable) from `src` into `dst`.

Recursively walks `dst` and `src` together using [`Functors.children`](@ref),
and calling `copyto!` on parameter arrays or throwing an error when there is a mismatch.
Non-array elements (such as activation functions) are not copied and need not match.
Zero bias vectors and `bias=false` are considered equivalent
(see extended help for more details).

See also [`Flux.state`](@ref).

# Examples
```julia
julia> dst = Chain(Dense(Flux.ones32(2, 5), Flux.ones32(2), tanh), Dense(2 => 1; bias = [1f0]))
Chain(
  Dense(5 => 2, tanh),                  # 12 parameters
  Dense(2 => 1),                        # 3 parameters
)                   # Total: 4 arrays, 15 parameters, 316 bytes.

julia> dst[1].weight ≈ ones(2, 5)  # by construction
true

julia> src = Chain(Dense(5 => 2, relu), Dense(2 => 1, bias=false));

julia> Flux.loadmodel!(dst, src);

julia> dst[1].weight ≈ ones(2, 5)  # values changed
false

julia> iszero(dst[2].bias)
true
```

# Extended help

Throws an error when:
- `dst` and `src` do not share the same fields (at any level)
- the sizes of leaf nodes are mismatched between `dst` and `src`
- copying non-array values to/from an array parameter
  (except inactive parameters described below)
- `dst` is a "tied" parameter (i.e. refers to another parameter) and
  loaded into multiple times with mismatched source values

Inactive parameters can be encoded by using the boolean value `false` instead of an array.
If `dst == false` and `src` is an all-zero array, no error will be raised (and no values copied);
however, attempting to copy a non-zero array to an inactive parameter will throw an error.
Likewise, copying a `src` value of `false` to any `dst` array is valid,
but copying a `src` value of `true` will error.
"""
function loadmodel!(dst, src; filter = _ -> true, cache = Base.IdSet())
  ldsts = _filter_children(filter, Functors.children(dst))
  lsrcs = _filter_children(filter, Functors.children(src))
  keys_ldsts = keys(ldsts)
  for k in keys(lsrcs)
    k ∈ keys_ldsts || throw(ArgumentError("Tried to load $(keys(lsrcs)) into $(keys(ldsts)) but the structures do not match."))
    lsrc, ldst = lsrcs[k], ldsts[k]
    if ldst in cache # we already loaded this parameter before
      _tie_check(ldst, lsrc) && return ldst
    elseif Functors.isleaf(ldst) # our first time loading this leaf
      push!(cache, ldst)
      loadleaf!(ldst, lsrc)
    else # this isn't a leaf
      loadmodel!(ldst, lsrc; filter, cache)
    end
  end

  return dst
end

"""
    state(x)

Return an object with the same nested structure as `x` according to `Functors.children`, 
but made only of basic containers (e.g. named tuples, tuples, arrays, and dictionaries).

Besides trainable and non-trainable arrays, the state will contain leaf nodes that are not arrays,
such as numbers, symbols, strings, and nothing values. The leaf types that end up in the state
could increase in the future.

This method is particularly useful for saving and loading models, 
since the state contain only simple data types that can be easily serialized.

The state can be passed to [`loadmodel!`](@ref) to restore the model.

# Examples

## Copy the state into another model

```jldoctest
julia> m1 = Chain(Dense(1, 2, tanh; init=ones), Dense(2, 1; init=ones));

julia> s = Flux.state(m1)
(layers = ((weight = [1.0; 1.0;;], bias = [0.0, 0.0]), (weight = [1.0 1.0], bias = [0.0])),)

julia> m2 = Chain(Dense(1, 2, tanh), Dense(2, 1; bias=false));  # weights are random numbers

julia> Flux.loadmodel!(m2, s);

julia> m2[1].weight   # now the weights of m2 are the same as m1
2×1 Matrix{Float32}:
 1.0
 1.0

julia> Flux.state(trainmode!(Dropout(0.2)))  # contains p & activity, but not RNG state
(p = 0.2, active = true)

julia> Flux.state(BatchNorm(1))  # contains non-trainable arrays μ, σ²
(β = Float32[0.0], γ = Float32[1.0], μ = Float32[0.0], σ² = Float32[1.0], ϵ = 1.0f-5, momentum = 0.1f0, affine = true, track_stats = true, active = nothing, chs = 1)
```

## Save and load with BSON

```julia-repl
julia> using BSON

julia> BSON.@save "checkpoint.bson" model_state = s

julia> Flux.loadmodel!(m2, BSON.load("checkpoint.bson")[:model_state])
```

## Save and load with JLD2

```julia-repl
julia> using JLD2

julia> JLD2.jldsave("checkpoint.jld2", model_state = s)

julia> Flux.loadmodel!(m2, JLD2.load("checkpoint.jld2", "model_state"))
```
"""
state(x) = Functors.fmapstructure(_state, x) |> prune_missing

const STATE_TYPES = Union{AbstractArray, Number, Nothing, AbstractString, Symbol}

_state(x::STATE_TYPES) = x
_state(x) = missing

prune_missing(x) = x

prune_missing(nt::NamedTuple) =
  (; (k => prune_missing(v) for (k,v) in pairs(nt) if !ismissing(v))...)

prune_missing(d::Dict) =
  Dict(k => prune_missing(v) for (k,v) in pairs(d) if !ismissing(v))

# we preserve missings in tuples to avoid ambiguities
prune_missing(t::Tuple) = prune_missing.(t) 

