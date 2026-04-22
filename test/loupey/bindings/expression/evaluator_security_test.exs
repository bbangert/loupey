defmodule Loupey.Bindings.Expression.EvaluatorSecurityTest do
  @moduledoc """
  Negative / security tests for `Loupey.Bindings.Expression.Evaluator`.

  The evaluator's whitelist is the security boundary. Every expression in
  this module is something a malicious or buggy binding YAML could contain;
  each MUST be rejected at `parse/1` time and MUST NOT execute.

  The old `Code.eval_string/2` path happily ran ALL of these. This module
  is the regression guard that ensures it stays gone.
  """

  use ExUnit.Case, async: true

  alias Loupey.Bindings.Expression.Evaluator

  # Each attack must fail at PARSE time — the AST walker never even sees it.
  # We assert on `:disallowed` to prove rejection came from the whitelist,
  # not from an accidental `rescue` that caught a runtime error.
  defp assert_rejected(source, expected_detail_shape \\ nil) do
    case Evaluator.parse(source) do
      {:error, {:disallowed, detail}} ->
        if expected_detail_shape do
          assert match_shape?(detail, expected_detail_shape),
                 "expected detail to match #{inspect(expected_detail_shape)}, got #{inspect(detail)}"
        end

        :ok

      {:error, {:parse, _}} ->
        # Syntax error from `Code.string_to_quoted` — also a rejection, but
        # via the parser not the whitelist. Accept it; these attacks should
        # never land in the walker regardless of which arm catches them.
        :ok

      {:ok, ast} ->
        flunk("""
        SECURITY REGRESSION: `#{source}` was accepted as valid.

        Parsed AST: #{inspect(ast)}

        This expression must be rejected before reaching `eval/2`.
        """)
    end
  end

  defp match_shape?(detail, {tag, _}) when is_tuple(detail) and elem(detail, 0) == tag, do: true
  defp match_shape?(_, _), do: false

  describe "remote module calls" do
    test "File.read! rejected" do
      assert_rejected(~s|File.read!("/etc/passwd")|, {:remote_call, nil})
    end

    test "File.rm_rf! rejected" do
      assert_rejected(~s|File.rm_rf!("/")|, {:remote_call, nil})
    end

    test "System.cmd rejected" do
      assert_rejected(~s|System.cmd("rm", ["-rf", "/"])|, {:remote_call, nil})
    end

    test "System.get_env rejected" do
      assert_rejected(~s|System.get_env("SECRET")|, {:remote_call, nil})
    end

    test ":os.cmd (erlang-style remote) rejected" do
      assert_rejected(~s|:os.cmd(~c"rm -rf /")|)
    end

    test "Code.eval_string rejected (defense in depth — evaluator must not call itself)" do
      assert_rejected(~s|Code.eval_string("System.halt()")|, {:remote_call, nil})
    end

    test "Process.exit rejected" do
      assert_rejected(~s|Process.exit(self(), :kill)|, {:remote_call, nil})
    end

    test "GenServer.call rejected" do
      assert_rejected(~s|GenServer.call(Loupey.Orchestrator, :status)|, {:remote_call, nil})
    end

    test "Enum.reduce (seemingly-benign pure fn) still rejected" do
      # We do not allow ANY module call. Hardening against the future case
      # where a seemingly-pure function has a surprise side effect.
      assert_rejected(~s|Enum.reduce([1], 0, fn x, a -> x + a end)|, {:remote_call, nil})
    end
  end

  describe "local calls outside the whitelist" do
    test "self() rejected" do
      assert_rejected("self()", {:local_call, nil})
    end

    test "apply/3 rejected" do
      assert_rejected(~s|apply(File, :read!, ["/etc/passwd"])|, {:local_call, nil})
    end

    test "spawn/1 rejected" do
      assert_rejected("spawn(fn -> :evil end)")
    end

    test "send/2 rejected" do
      assert_rejected("send(self(), :ping)", {:local_call, nil})
    end

    test "make_ref/0 rejected" do
      assert_rejected("make_ref()", {:local_call, nil})
    end

    test "is_atom/1 (harmless-looking but unlisted) rejected" do
      # Contract is whitelist-only. Nothing implicit.
      assert_rejected("is_atom(state)", {:local_call, nil})
    end
  end

  describe "anonymous functions and captures" do
    test "fn -> ... end rejected" do
      assert_rejected("fn -> :evil end")
    end

    test "fn with arg rejected" do
      assert_rejected("fn x -> x + 1 end")
    end

    test "& capture rejected" do
      assert_rejected("&File.read!/1")
    end

    test "& short-form capture rejected" do
      assert_rejected("&(&1 + 1)")
    end
  end

  describe "compile-time specials" do
    test "__ENV__ rejected" do
      assert_rejected("__ENV__", {:special_form, nil})
    end

    test "__MODULE__ rejected" do
      assert_rejected("__MODULE__", {:special_form, nil})
    end

    test "__CALLER__ rejected" do
      assert_rejected("__CALLER__", {:special_form, nil})
    end

    test "__STACKTRACE__ rejected" do
      assert_rejected("__STACKTRACE__", {:special_form, nil})
    end

    test "__DIR__ rejected" do
      assert_rejected("__DIR__", {:special_form, nil})
    end
  end

  describe "atom literals" do
    test ":arbitrary_atom rejected" do
      assert_rejected(":some_atom", {:atom_literal, nil})
    end

    test ":kill (process-killing reason) rejected" do
      assert_rejected(":kill", {:atom_literal, nil})
    end
  end

  describe "control-flow and structural forms" do
    test "case rejected" do
      assert_rejected("case state do\n  \"on\" -> 1\n  _ -> 0\nend")
    end

    test "if rejected" do
      # `if` is a macro → a local call in AST. Not in our whitelist.
      assert_rejected(~s|if state == "on", do: 1, else: 0|)
    end

    test "cond rejected" do
      assert_rejected("cond do\n  state == \"on\" -> 1\n  true -> 0\nend")
    end

    test "try/rescue rejected" do
      assert_rejected("try do\n  :ok\nrescue\n  _ -> :err\nend")
    end

    test "receive rejected" do
      assert_rejected("receive do\n  msg -> msg\nend")
    end

    test "pipe rejected (the |> macro expands to a local call `|>`)" do
      assert_rejected("\"hi\" |> String.upcase()")
    end

    test "module attr @foo rejected" do
      assert_rejected("@some_attr")
    end
  end

  describe "defense in depth" do
    test "String.to_atom (atom-exhaustion vector) rejected" do
      # Not strictly relevant post-BLOCKER-#3 + yaml-parser fix, but the
      # evaluator must not open a side channel back into atom creation.
      assert_rejected(~s|String.to_atom("foo")|, {:remote_call, nil})
    end

    test "Kernel.apply rejected" do
      assert_rejected(~s|Kernel.apply(File, :read!, ["/etc/passwd"])|, {:remote_call, nil})
    end

    test ":erlang.halt rejected" do
      assert_rejected(":erlang.halt()")
    end

    test "ErlangTerm.* rejected (any unknown Module path)" do
      assert_rejected(~s|Loupey.Orchestrator.deactivate_profile(1)|, {:remote_call, nil})
    end

    test "complex nested malicious expression still rejected at first disallowed node" do
      # Outer shape is arithmetic which is OK, but the inner call to
      # File.read! must fail the whole parse.
      assert_rejected(~s|1 + String.length(File.read!("/etc/passwd"))|)
    end

    test "whitelisted call with a disallowed argument is rejected" do
      # `round(...)` is allowed, but the argument contains an unsafe call.
      assert_rejected(~s|round(File.read!("/etc/passwd"))|)
    end
  end

  describe "access sugar specifically" do
    test "map[key] (bracket form) IS allowed" do
      assert {:ok, _} = Evaluator.parse(~s|attributes["brightness"]|)
    end

    test "Access.get(map, key) (remote call) rejected" do
      # Only the bracket-sugared form is recognized; the remote form is
      # treated like any other `Module.fun(args)`.
      assert_rejected(~s|Access.get(attributes, "brightness")|, {:remote_call, nil})
    end
  end
end
