module ReactiveTools

using Stipple
using MacroTools
using MacroTools: postwalk
using OrderedCollections
import Genie
import Stipple: deletemode!, parse_expression!, init_storage

export @readonly, @private, @in, @out, @jsfn, @readonly!, @private!, @in!, @out!, @jsfn!
export @mix_in, @clear, @vars, @add_vars
export @page, @rstruct, @type, @handlers, @init, @model, @onchange, @onchangeany, @onbutton
export DEFAULT_LAYOUT, Page

const REACTIVE_STORAGE = LittleDict{Module,LittleDict{Symbol,Expr}}()
const HANDLERS = LittleDict{Module,Vector{Expr}}()
const TYPES = LittleDict{Module,Union{<:DataType,Nothing}}()

function DEFAULT_LAYOUT(; title::String = "Genie App")
  """
<!DOCTYPE html>
<html>
  <head>
    <meta charset="utf-8">
    <% Stipple.sesstoken() %>
    <title>$title</title>
    <% if isfile(joinpath(Genie.config.server_document_root, "css", "genieapp.css")) %>
    <link rel='stylesheet' href='/css/genieapp.css'>
    <% else %>
    <% end %>
    <% if isfile(joinpath(Genie.config.server_document_root, "css", "autogenerated.css")) %>
    <link rel='stylesheet' href='/css/autogenerated.css'>
    <% else %>
    <% end %>
    <style>
      ._genie_logo {
        background:url('/stipple.jl/master/assets/img/genie-logo.img') no-repeat;background-size:40px;
        padding-top:22px;padding-right:10px;color:transparent;font-size:9pt;
      ._genie .row .col-12 { width:50%;margin:auto; }
      }
    </style>
  </head>
  <body>
    <div class='container'>
      <div class='row'>
        <div class='col-12'>
          <% page(model, partial = true, v__cloak = true, [@yield], @iif(:isready)) %>
        </div>
      </div>
    </div>
    <% if isfile(joinpath(Genie.config.server_document_root, "js", "genieapp.js")) %>
    <script src='/js/genieapp.js'></script>
    <% else %>
    <% end %>
    <footer class='_genie container'>
      <div class='row'>
        <div class='col-12'>
          <p class='text-muted credit' style='text-align:center;color:#8d99ae;'>Built with
            <a href='https://genieframework.com' target='_blank' class='_genie_logo' ref='nofollow'>Genie</a>
          </p>
        </div>
      </div>
    </footer>
  </body>
</html>
"""
end

function default_struct_name(m::Module)
  "$(m)_ReactiveModel"
end

function Stipple.init_storage(m::Module)
  (m == @__MODULE__) && return nothing 
  haskey(REACTIVE_STORAGE, m) || (REACTIVE_STORAGE[m] = Stipple.init_storage())
  haskey(TYPES, m) || (TYPES[m] = nothing)
end

function Stipple.setmode!(expr::Expr, mode::Int, fieldnames::Symbol...)
  fieldname in [Stipple.CHANNELFIELDNAME, :_modes] && return

  d = eval(expr.args[2])
  for fieldname in fieldnames
    mode == PUBLIC ? delete!(d, fieldname) : d[fieldname] = mode
  end
  expr.args[2] = QuoteNode(d)
end

#===#

function clear_type(m::Module)
  TYPES[m] = nothing
end

function delete_bindings!(m::Module)
  clear_type(m)
  delete!(REACTIVE_STORAGE, m)
  delete!(HANDLERS, m)
end

function bindings(m)
  init_storage(m)
  REACTIVE_STORAGE[m]
end

#===#

macro clear()
  delete_bindings!(__module__)
end

macro clear(args...)
  haskey(REACTIVE_STORAGE, __module__) || return
  for arg in args
    arg in [Stipple.CHANNELFIELDNAME, :_modes] && continue
    delete!(REACTIVE_STORAGE[__module__], arg)
  end
  deletemode!(REACTIVE_STORAGE[__module__][:_modes], args...)

  update_storage(__module__)

  REACTIVE_STORAGE[__module__]
end

import Stipple.@type
macro type()  
  Stipple.init_storage(__module__)
  type = if TYPES[__module__] !== nothing
    TYPES[__module__]
  else
    modelname = Symbol(default_struct_name(__module__))
    storage = REACTIVE_STORAGE[__module__]
    TYPES[__module__] = @eval(__module__, Stipple.@type($modelname, $storage))
  end

  esc(:($type))
end

function update_storage(m::Module)
  clear_type(m)
  # isempty(Stipple.Pages._pages) && return
  # instance = @eval m Stipple.@type()
  # for p in Stipple.Pages._pages
  #   p.context == m && (p.model = instance)
  # end
end

import Stipple: @vars, @add_vars

macro vars(expr)
  init_storage(__module__)
  
  REACTIVE_STORAGE[__module__] = @eval(__module__, Stipple.@var_storage($expr))

  update_storage(__module__)
end

macro add_vars(expr)
  init_storage(__module__)
  REACTIVE_STORAGE[__module__] = Stipple.merge_storage(REACTIVE_STORAGE[__module__], @eval(__module__, Stipple.@var_storage($expr)))

  update_storage(__module__)
end

macro model()
  esc(quote
    ReactiveTools.@type() |> Base.invokelatest
  end)
end

#===#

function binding(expr::Symbol, m::Module, @nospecialize(mode::Any = nothing); source = nothing, reactive = true)
  binding(:($expr = $expr), m, mode; source, reactive)
end

function binding(expr::Expr, m::Module, @nospecialize(mode::Any = nothing); source = nothing, reactive = true)
  (m == @__MODULE__) && return nothing

  intmode = @eval Stipple $mode
  init_storage(m)

  var, field_expr = parse_expression!(expr, reactive ? mode : nothing, source, m)
  REACTIVE_STORAGE[m][var] = field_expr

  reactive || setmode!(REACTIVE_STORAGE[m][:_modes], intmode, var)
  reactive && setmode!(REACTIVE_STORAGE[m][:_modes], PUBLIC, var)

  # remove cached type and instance, update pages
  update_storage(m)
end

# this macro needs to run in a macro where `expr`is already defined
macro report_val()
  quote
    val = expr isa Symbol ? expr : expr.args[2]
    issymbol = val isa Symbol
    :(if $issymbol
      if isdefined(@__MODULE__, $(QuoteNode(val)))
        $val
      else
        @info(string("Warning: Variable '", $(QuoteNode(val)), "' not yet defined"))
      end
    else
      Stipple.Observables.to_value($val)
    end) |> esc
  end |> esc
end

# this macro needs to run in a macro where `expr`is already defined
macro define_var()
  quote
    ( expr isa Symbol || expr.head !== :(=) ) && return expr
    var = expr.args[1] isa Symbol ? expr.args[1] : expr.args[1].args[1]
    new_expr = :($var = Stipple.Observables.to_value($(expr.args[2])))
    esc(:($new_expr))
  end |> esc
end

# works with
# @in a = 2
# @in a::Vector = [1, 2, 3]
# @in a::Vector{Int} = [1, 2, 3]
macro in(expr)
  binding(copy(expr), __module__, :PUBLIC; source = __source__)
  # @define_var()
  esc(:($expr))
end

macro in(flag, expr)
  flag != :non_reactive && return esc(:(ReactiveTools.@in($expr)))
  binding(copy(expr), __module__, :PUBLIC; source = __source__, reactive = false)
  # @define_var()
  esc(:($expr))
end

macro in!(expr)
  binding(expr, __module__, :PUBLIC; source = __source__)
  @report_val()
end

macro in!(flag, expr)
  flag != :non_reactive && return esc(:(ReactiveTools.@in($expr)))
  binding(expr, __module__, :PUBLIC; source = __source__, reactive = false)
  @report_val()
end

macro out(expr)
  binding(copy(expr), __module__, :READONLY; source = __source__)
  # @define_var()
  esc(:($expr))
end

macro out(flag, expr)
  flag != :non_reactive && return esc(:(@out($expr)))

  binding(copy(expr), __module__, :READONLY; source = __source__, reactive = false)
  # @define_var()
  esc(:($expr))
end

macro out!(expr)
  binding(expr, __module__, :READONLY; source = __source__)
  @report_val()
end

macro out!(flag, expr)
  flag != :non_reactive && return esc(:(@out($expr)))

  binding(expr, __module__, :READONLY; source = __source__, reactive = false)
  @report_val()
end

macro readonly(expr)
  esc(:(ReactiveTools.@out($expr)))
end

macro readonly(flag, expr)
  esc(:(ReactiveTools.@out($flag, $expr)))
end

macro readonly!(expr)
  esc(:(ReactiveTools.@out!($expr)))
end

macro readonly!(flag, expr)
  esc(:(ReactiveTools.@out!($flag, $expr)))
end

macro private(expr)
  binding(copy(expr), __module__, :PRIVATE; source = __source__)
  # @define_var()
  esc(:($expr))
end

macro private(flag, expr)
  flag != :non_reactive && return esc(:(ReactiveTools.@private($expr)))

  binding(copy(expr), __module__, :PRIVATE; source = __source__, reactive = false)
  # @define_var()
  esc(:($expr))
end

macro private!(expr)
  binding(expr, __module__, :PRIVATE; source = __source__)
  @report_val()
end

macro private!(flag, expr)
  flag != :non_reactive && return esc(:(ReactiveTools.@private($expr)))

  binding(expr, __module__, :PRIVATE; source = __source__, reactive = false)
  @report_val()
end

macro jsfn(expr)
  binding(copy(expr), __module__, :JSFUNCTION; source = __source__)
  # @define_var()
  esc(:($expr))
end

macro jsfn!(expr)
  binding(expr, __module__, :JSFUNCTION; source = __source__)
  @report_val()
end

macro mix_in(expr, prefix = "", postfix = "")
  init_storage(__module__)

  if hasproperty(expr, :head) && expr.head == :(::)
      prefix = string(expr.args[1])
      expr = expr.args[2]
  end

  x = Core.eval(__module__, expr)
  pre = Core.eval(__module__, prefix)
  post = Core.eval(__module__, postfix)

  T = x isa DataType ? x : typeof(x)
  mix = x isa DataType ? x() : x
  values = getfield.(Ref(mix), fieldnames(T))
  ff = Symbol.(pre, fieldnames(T), post)
  for (f, type, v) in zip(ff, fieldtypes(T), values)
      v_copy = Stipple._deepcopy(v)
      expr = :($f::$type = Stipple._deepcopy(v))
      REACTIVE_STORAGE[__module__][f] = v isa Symbol ? :($f::$type = $(QuoteNode(v))) : :($f::$type = $v_copy)
  end

  update_storage(__module__)
  esc(Stipple.Observables.to_value.(values))
end

#===#

macro init(modeltype)
  if isdefined(__module__, :__GF_AUTO_HANDLERS__)
    @eval(__module__, length(methods(__GF_AUTO_HANDLERS__)) == 0 && @handlers)
  end
  quote
    local initfn =  if isdefined($__module__, :init_from_storage)
                      $__module__.init_from_storage
                    else
                      $__module__.init
                    end
    local handlersfn =  if isdefined($__module__, :__GF_AUTO_HANDLERS__)
                          $__module__.__GF_AUTO_HANDLERS__
                        else
                          identity
                        end

    instance = $modeltype |> initfn |> handlersfn
    for p in Stipple.Pages._pages
      p.context == $__module__ && (p.model = instance)
    end
    instance
  end |> esc
end

macro init()
  quote
    let type = @type
      @init(type)
    end
  end |> esc
end

macro handlers()
  handlers = get!(Vector{Expr}, HANDLERS, __module__)
  quote
    function __GF_AUTO_HANDLERS__(__model__)
      $(handlers...)

      return __model__
    end
  end |> esc
end

macro handlers(expr)
  handlers = get!(Vector{Expr}, HANDLERS, __module__)
  empty!(handlers)
  quote
    $expr
    eval(:(function __GF_AUTO_HANDLERS__(__model__)
      $(handlers...)

      return __model__
    end))
  end |> esc
end

function wrap(expr, wrapper = nothing)
  if wrapper !== nothing && (! isa(expr, Expr) || expr.head != wrapper)
    Expr(wrapper, expr)
  else
    expr
  end
end

function transform(expr, vars::Vector{Symbol}, test_fn::Function, replace_fn::Function)
  replaced_vars = Symbol[]
  ex = postwalk(expr) do x
      if x isa Expr
          if x.head == :call
              f = x
              while f.args[1] isa Expr && f.args[1].head == :ref
                  f = f.args[1]
              end
              if f.args[1] isa Symbol && test_fn(f.args[1])
                  union!(push!(replaced_vars, f.args[1]))
                  f.args[1] = replace_fn(f.args[1])
              end
          elseif x.head == :kw && test_fn(x.args[1])
              x.args[1] = replace_fn(x.args[1])
          elseif x.head == :parameters
              for (i, a) in enumerate(x.args)
                  if a isa Symbol && test_fn(a)
                    new_a = replace_fn(a)
                    x.args[i] = new_a in vars ? :($(Expr(:kw, new_a, :(__model__.$new_a[])))) : new_a
                  end
              end
          end
      end
      x
  end
  ex, replaced_vars
end

mask(expr, vars::Vector{Symbol}) = transform(expr, vars, in(vars), x -> Symbol("_mask_$x"))
unmask(expr, vars = Symbol[]) = transform(expr, vars, x -> startswith(string(x), "_mask_"), x -> Symbol(string(x)[7:end]))[1]

function fieldnames_to_fields(expr, vars)
  postwalk(expr) do x
    x isa Symbol && x ∈ vars ? :(__model__.$x) : x
  end
end

function fieldnames_to_fieldcontent(expr, vars)
  postwalk(expr) do x
    x isa Symbol && x ∈ vars ? :(__model__.$x[]) : x
  end
end

function get_known_vars(M::Module)
  push!(REACTIVE_STORAGE[M] |> keys |> collect, :isready, :isprocessing)
end

macro onchange(vars, expr)
  vars = wrap(vars, :tuple)
  expr = wrap(expr, :block)

  get!(Vector{Expr}, HANDLERS, __module__)

  known_vars = get_known_vars(__module__)
  on_vars = fieldnames_to_fields(vars, known_vars)

  expr, used_vars = mask(expr, known_vars)
  do_vars = :()

  for a in vars.args
    push!(do_vars.args, a isa Symbol && ! in(a, used_vars) ? a : :_)
  end

  known_vars = setdiff(known_vars, setdiff(vars.args, used_vars)) |> Vector{Symbol}
  expr = unmask(fieldnames_to_fieldcontent(expr, known_vars), known_vars)

  fn = length(vars.args) == 1 ? :on : :onany
  ex = quote
    $fn($(on_vars.args...)) do $(do_vars.args...)
        $(expr.args...)
    end
  end

  push!(HANDLERS[__module__], ex)

  quote
    function __GF_AUTO_HANDLERS__ end
    Base.delete_method.(methods(__GF_AUTO_HANDLERS__))
    Stipple.ReactiveTools.HANDLERS[@__MODULE__][end]
  end |> esc
end

macro onchangeany(vars, expr)
  quote
    @warn("The macro `@onchangeany` is deprecated and should be replaced by `@onchange`")
    @onchange $vars $expr
  end |> esc
end

macro onbutton(var, expr)
  expr = wrap(expr, :block)
  get!(Vector{Expr}, HANDLERS, __module__)

  known_vars = get_known_vars(__module__)
  var = fieldnames_to_fields(var, known_vars)

  expr, used_vars = mask(expr, known_vars)
  expr = unmask(fieldnames_to_fieldcontent(expr, known_vars), known_vars)

  ex = :(onbutton($var) do
    $(expr.args...)
  end)
  push!(HANDLERS[__module__], ex)
  
  quote
    function __GF_AUTO_HANDLERS__ end
    Base.delete_method.(methods(__GF_AUTO_HANDLERS__))
    Stipple.ReactiveTools.HANDLERS[@__MODULE__][end]
  end |> esc
end

#===#

macro page(url, view, layout, model, context)
  quote
    Stipple.Pages.Page( $url;
                        view = $view,
                        layout = $layout,
                        model = $model,
                        context = $context)
  end |> esc
end

macro page(url, view, layout, model)
  :(@page($url, $view, $layout, $model, $__module__)) |> esc
end

macro page(url, view, layout)
  :(@page($url, $view, $layout, () -> @eval($__module__, @init()))) |> esc
end

macro page(url, view)
  :(@page($url, $view, Stipple.ReactiveTools.DEFAULT_LAYOUT())) |> esc
end

# macros for model-specific js functions on the front-end (see Vue.js docs)

export @methods, @watch, @computed, @created, @mounted, @event, @client_data, @add_client_data

macro methods(expr)
  esc(quote
    let M = @type
      Stipple.js_methods(::M) = $expr
    end
  end)
end

macro watch(expr)
  esc(quote
    let M = @type
      Stipple.js_watch(::M) = $expr
    end
  end)
end

macro computed(expr)
  esc(quote
    let M = @type
      Stipple.js_computed(::M) = $expr
    end
  end)
end

macro created(expr)
  esc(quote
    let M = @type
      Stipple.js_created(::M) = $expr
    end
  end)
end

macro mounted(expr)
  esc(quote
    let M = @type
      Stipple.js_mounted(::M) = $expr
    end
  end)
end

macro event(event, expr)
  known_vars = get_known_vars(__module__)

  expr, used_vars = mask(expr, known_vars)
  expr = unmask(fieldnames_to_fieldcontent(expr, known_vars), known_vars)
  
  quote
    let M = @type, T = $(event isa QuoteNode ? event : QuoteNode(event))
      function Base.notify(__model__::M, ::Val{T}, @nospecialize(event))
        $expr
      end
    end
  end |> esc
end

macro client_data(expr)
  if expr.head != :block
    expr = quote $expr end
  end

  output = :(Stipple.client_data())
  for e in expr.args
    e isa LineNumberNode && continue
    e.head = :kw
    push!(output.args, e)
  end

  esc(quote
    let M = @type
      Stipple.client_data(::M) = $output
    end
  end)
end

macro add_client_data(expr)
  if expr.head != :block
    expr = quote $expr end
  end

  output = :(Stipple.client_data())
  for e in expr.args
    e isa LineNumberNode && continue
    e.head = :kw
    push!(output.args, e)
  end

  esc(quote
    let M = @type
      cd_old = Stipple.client_data(M())
      cd_new = $output
      Stipple.client_data(::M) = merge(d1, d2)
    end
  end)
end

end