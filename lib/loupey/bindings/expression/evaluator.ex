defmodule Loupey.Bindings.Expression.Evaluator do
  @moduledoc """
  Safe, interpreted evaluator for Loupey's binding-expression DSL.

  ## Two-phase design

  - `parse/1` — Elixir source → normalized AST (tagged tuples).
    The whitelist check runs here; anything not in the allowed grammar
    is rejected before eval ever runs. This is the security boundary.
  - `eval/2` — walk a pre-parsed AST against a context map.
    Pattern-matches only the tagged shapes produced by `parse/1`.

  Callers that render repeatedly (output rules on HA state changes) should
  `parse/1` once at binding-load time and hold the AST; `eval/2` then skips
  all parse + normalize work. For one-shots, `evaluate/2` combines them.

  ## Grammar

      expr := literal | variable | call | binop | unary | access

      literal  := integer | float | string | true | false | nil
      variable := identifier          (looked up in context; undefined → nil)

      call     := "state_of" "(" expr ")"
                | "attr_of"  "(" expr "," expr ")"
                | "round"    "(" expr ")"

      binop    := expr ("==" | "!=" | ">" | "<" | ">=" | "<=") expr
                | expr ("+"  | "-"  | "*" | "/" )              expr
                | expr "||"  expr

      unary    := "-" expr
      access   := expr "[" expr "]"   (Access.get/2 on maps)

  No atom literals, no anonymous functions, no captures, no pipes,
  no module-qualified calls, no `apply`, no `spawn`, no compile-time
  specials (`__ENV__` et al.), no `and`/`or`/`not` keywords.
  Anything outside this grammar → `{:error, {:disallowed, …}}` at parse.

  ## Context shape

  The `context` passed to `eval/2`/`evaluate/2` is a plain map of
  variable-name atoms to values, plus two function entries used to
  resolve `state_of/1` and `attr_of/2`:

      %{
        # Variables referenced in expressions
        state: "on" | nil,
        attributes: %{"brightness" => 255, ...},
        entity_id: "light.office",
        touch_x: 0, touch_y: 42,
        # …any other context vars

        # Helper-call resolvers (injected by Expression wrapper)
        state_of: fn id -> ... end,       # arity 1, returns state string | nil
        attr_of:  fn id, key -> ... end   # arity 2, returns attr value | nil
      }

  """

  @type ast ::
          {:lit, integer() | float() | binary() | boolean() | nil}
          | {:var, atom()}
          | {:call, :state_of | :attr_of | :round, [ast()]}
          | {:op, :== | :!= | :> | :< | :>= | :<= | :+ | :- | :* | :/ | :||, [ast(), ...]}
          | {:neg, ast()}
          | {:access, ast(), ast()}

  @allowed_calls %{state_of: 1, attr_of: 2, round: 1}
  @allowed_binary_ops ~w(== != > < >= <= + - * /)a
  # `||` is handled specially for short-circuit semantics.

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Parse `source` into a normalized AST.

  Returns `{:ok, ast}` if every node fits the allowed grammar; otherwise
  `{:error, reason}` where reason is one of:

    * `{:parse, detail}` — `Code.string_to_quoted/1` reported a syntax error
    * `{:disallowed, shape}` — a node in the AST is not in the whitelist
  """
  @spec parse(String.t()) :: {:ok, ast()} | {:error, term()}
  def parse(source) when is_binary(source) do
    case Code.string_to_quoted(source) do
      {:ok, quoted} -> normalize(quoted)
      {:error, reason} -> {:error, {:parse, reason}}
    end
  rescue
    e -> {:error, {:parse, Exception.message(e)}}
  end

  @doc """
  Evaluate a pre-parsed AST against `context`.

  Returns `{:ok, value}` on success, `{:error, {:eval, message}}` if an
  arithmetic/match error surfaces during the walk.

  `context` is a plain map; variable references look up keys by atom name.
  Missing keys resolve to `nil` (matches the `Code.eval_string` rescue
  behavior of the original `Expression.eval/2`).
  """
  @spec eval(ast(), map()) :: {:ok, term()} | {:error, term()}
  def eval(ast, context) when is_map(context) do
    {:ok, walk(ast, context)}
  rescue
    e -> {:error, {:eval, Exception.message(e)}}
  end

  @doc """
  Parse + eval in one call, with **per-process AST memoization**.

  The parsed AST is cached in the calling process's dictionary keyed by
  source. Subsequent calls for the same source skip parse/normalize and go
  straight to `eval/2`. Intended for callers that can't (or don't yet)
  hold the AST in a struct — they pay the parse cost once per process per
  unique source, which in practice means once per binding per engine.

  Parse *errors* are not cached — the source may be corrected at runtime
  (e.g. binding edited in the UI).

  Thread safety: process dictionary is per-process, so cache entries are
  isolated. No lock contention, no cross-process sharing.
  """
  @spec evaluate(String.t(), map()) :: {:ok, term()} | {:error, term()}
  def evaluate(source, context) do
    with {:ok, ast} <- cached_parse(source), do: eval(ast, context)
  end

  @doc """
  Clear this process's AST cache. Primarily for tests that want to
  measure cold-parse behavior; not needed for correctness.
  """
  @spec clear_cache() :: :ok
  def clear_cache do
    for {{__MODULE__, _} = key, _} <- Process.get() do
      Process.delete(key)
    end

    :ok
  end

  defp cached_parse(source) do
    case Process.get({__MODULE__, source}) do
      nil ->
        case parse(source) do
          {:ok, _ast} = ok ->
            Process.put({__MODULE__, source}, ok)
            ok

          {:error, _} = err ->
            err
        end

      cached ->
        cached
    end
  end

  # ---------------------------------------------------------------------------
  # Normalize: raw Elixir AST → our tagged AST
  # ---------------------------------------------------------------------------

  # Literals. The Elixir parser returns bare values for integer/float/string
  # and for the atoms true/false/nil (the only atoms we permit).
  defp normalize(v) when is_integer(v) or is_float(v) or is_binary(v), do: {:ok, {:lit, v}}
  defp normalize(v) when v in [true, false, nil], do: {:ok, {:lit, v}}

  # Any other bare atom (including `:foo`, `:state_of` as a capture, `Module`
  # aliases already reduced elsewhere) → reject. Atoms are a privileged type
  # on the BEAM; we don't let untrusted source pick them.
  defp normalize(atom) when is_atom(atom), do: disallowed({:atom_literal, atom})

  # Map access: `map[key]` desugars to `Access.get(map, key)` with a special
  # `from_brackets: true` metadata flag. Match the exact shape.
  defp normalize({{:., _, [Access, :get]}, meta, [map, key]}) do
    if Keyword.get(meta, :from_brackets, false) do
      with {:ok, map_ast} <- normalize(map),
           {:ok, key_ast} <- normalize(key) do
        {:ok, {:access, map_ast, key_ast}}
      end
    else
      # `Access.get(map, key)` written as a remote call is still disallowed —
      # we only recognize the bracket-sugared form.
      disallowed({:remote_call, {Access, :get, 2}})
    end
  end

  # Any other remote call `Mod.fun(args)` → reject. Covers `File.read!`,
  # `System.cmd`, `:os.cmd`, `Process.exit`, etc.
  defp normalize({{:., _, [{:__aliases__, _, path}, fun]}, _, args}) when is_list(args) do
    disallowed({:remote_call, {Module.concat(path), fun, length(args)}})
  end

  # `:module.fun(args)` (Erlang-style remote call with an atom-as-module) → reject.
  defp normalize({{:., _, [mod, fun]}, _, args}) when is_atom(mod) and is_list(args) do
    disallowed({:remote_call, {mod, fun, length(args)}})
  end

  # Compile-time specials: `__ENV__`, `__MODULE__`, `__CALLER__`, etc. have
  # the same AST shape as a variable reference but are privileged. Reject by
  # name-prefix before the variable branch can absorb them.
  defp normalize({name, _, context}) when is_atom(name) and is_atom(context) do
    name_s = Atom.to_string(name)

    cond do
      String.starts_with?(name_s, "__") and String.ends_with?(name_s, "__") ->
        disallowed({:special_form, name})

      true ->
        {:ok, {:var, name}}
    end
  end

  # Local call: `state_of(x)`, `attr_of(x, y)`, `round(x)`.
  # Any other local call (including `self()`, `apply(...)`, `spawn(...)`,
  # user-defined-sounding calls) → reject.
  defp normalize({name, _, args}) when is_atom(name) and is_list(args) do
    cond do
      name == :|| ->
        normalize_binary_op(:||, args)

      name in @allowed_binary_ops and length(args) == 2 ->
        normalize_binary_op(name, args)

      name == :- and length(args) == 1 ->
        normalize_unary_minus(args)

      Map.has_key?(@allowed_calls, name) and @allowed_calls[name] == length(args) ->
        normalize_local_call(name, args)

      true ->
        disallowed({:local_call, {name, length(args)}})
    end
  end

  # Anything else — `{:fn, …}`, `{:&, …}`, `{:@, …}`, `{:try, …}`,
  # `{:case, …}`, tuples, lists, etc. — reject.
  defp normalize(other), do: disallowed({:ast_shape, other})

  defp normalize_binary_op(op, [left, right]) do
    with {:ok, l} <- normalize(left),
         {:ok, r} <- normalize(right) do
      {:ok, {:op, op, [l, r]}}
    end
  end

  defp normalize_unary_minus([arg]) do
    with {:ok, a} <- normalize(arg), do: {:ok, {:neg, a}}
  end

  defp normalize_local_call(name, args) do
    with {:ok, normalized} <- normalize_args(args, []) do
      {:ok, {:call, name, normalized}}
    end
  end

  defp normalize_args([], acc), do: {:ok, Enum.reverse(acc)}

  defp normalize_args([arg | rest], acc) do
    with {:ok, a} <- normalize(arg), do: normalize_args(rest, [a | acc])
  end

  defp disallowed(detail), do: {:error, {:disallowed, detail}}

  # ---------------------------------------------------------------------------
  # Walk: normalized AST + context → value
  # ---------------------------------------------------------------------------

  defp walk({:lit, v}, _ctx), do: v

  defp walk({:var, name}, ctx), do: Map.get(ctx, name)

  defp walk({:access, map_ast, key_ast}, ctx) do
    map = walk(map_ast, ctx)
    key = walk(key_ast, ctx)

    case map do
      m when is_map(m) -> Map.get(m, key)
      nil -> nil
      _ -> raise ArgumentError, "access on non-map value"
    end
  end

  # Short-circuit `||` — MUST NOT evaluate the RHS when LHS is truthy.
  defp walk({:op, :||, [left, right]}, ctx) do
    case walk(left, ctx) do
      v when v in [false, nil] -> walk(right, ctx)
      v -> v
    end
  end

  defp walk({:op, op, [left, right]}, ctx) do
    l = walk(left, ctx)
    r = walk(right, ctx)
    apply_binop(op, l, r)
  end

  defp walk({:neg, arg}, ctx), do: -walk(arg, ctx)

  defp walk({:call, :round, [arg]}, ctx), do: Kernel.round(walk(arg, ctx))

  defp walk({:call, :state_of, [arg]}, ctx) do
    fun = Map.fetch!(ctx, :state_of)
    fun.(walk(arg, ctx))
  end

  defp walk({:call, :attr_of, [id_ast, key_ast]}, ctx) do
    fun = Map.fetch!(ctx, :attr_of)
    fun.(walk(id_ast, ctx), walk(key_ast, ctx))
  end

  defp apply_binop(:==, l, r), do: l == r
  defp apply_binop(:!=, l, r), do: l != r
  defp apply_binop(:>, l, r), do: l > r
  defp apply_binop(:<, l, r), do: l < r
  defp apply_binop(:>=, l, r), do: l >= r
  defp apply_binop(:<=, l, r), do: l <= r
  defp apply_binop(:+, l, r), do: l + r
  defp apply_binop(:-, l, r), do: l - r
  defp apply_binop(:*, l, r), do: l * r
  defp apply_binop(:/, l, r), do: l / r
end
