defmodule Zigler.Unit do

  @moduledoc """
  Hooks your zig code into ExUnit, by converting zig tests into ExUnit tests.

  ### Usage

  #### Example

  Inside your zig code (`dependent.zig`):
  ```
  const beam = @import("beam.zig");
  const assert = beam.assert;

  fn one() i64 {
    return 1;
  }

  test "the one function returns one" {
    assert(one() == 1);
  }
  ```

  Inside your elixir code:

  ```
  defmodule MyZigModule do
    use Zigler, otp_app: :my_app

    ~Z\"""
    const dependent = @import("dependent.zig");

    /// nif: some_nif_fn/1
    ...
    \"""
  end
  ```

  Inside your test module:

  ```
  defmodule MyZigTest do
    use ExUnit.Case, async: true
    use Zigler.Unit

    zigtest MyZigModule
  end
  ```

  ### Scope

  This module will run tests in all zig code that resides in the same code
  directory as the base module (or overridden directory, if applicable).  Zig
  code in subdirectories will not be subjected to test conversion, so if you
  would like to run a subset of tests using the Zig test facility (and without
  the support of a BEAM VM), you should put them in subdirectories.
  """

  defstruct [:title, :name]

  @typedoc false
  @type t :: %__MODULE__{title: String.t, }

  alias Zigler.Unit.Parser

  @doc false
  def string_to_hash(str) do
    hash = :md5
    |> :crypto.hash(str)
    |> Base.encode16

    "test_" <> hash
  end

  defmacro __using__(_) do
    quote do
      # tests are always going to be released in safe mode.
      @release_mode :safe
      @on_load :__load_nifs__

      # don't persist the app or the version, we are going to get that from the parent.
      Module.register_attribute(__MODULE__, :zig_specs, accumulate: true)
      Module.register_attribute(__MODULE__, :zig_code, accumulate: true, persist: true)
      Module.register_attribute(__MODULE__, :zig_imports, accumulate: true)
      Module.register_attribute(__MODULE__, :zig_src_dir, persist: true)
      Module.register_attribute(__MODULE__, :zig_test, persist: true)

      @zig_test true

      @before_compile Zigler.Compiler

      import Zigler.Unit
    end
  end

  @doc """
  loads a module that wraps a zigler NIF, consults the corresponding zig code,
  generating the corresponding zig tests.

  Must be called from within a module that has run `use ExUnit.Case`.
  """
  defmacro zigtest(mod) do

    Process.sleep(5000)

    module = Macro.expand(mod, __CALLER__)

    source_file = module.__info__(:compile)[:source]
    src_dir = Path.dirname(source_file)

    code = module.__info__(:attributes)[:zig_code]
    |> IO.iodata_to_binary
    |> Parser.get_tests(source_file)

    [zigler_app] = module.__info__(:attributes)[:zigler_app]
    [zig_version] = module.__info__(:attributes)[:zig_version]
    zig_resources = module.__info__(:attributes)[:zig_resources]

    code_spec = Enum.map(code.tests, &{&1.name, {[], "void"}})

    empty_functions = code.tests
    |> Enum.map(&%{&1 | name: &1.name |> String.split(".") |> List.last})
    |> Enum.map(&Zigler.empty_function(String.to_atom(&1.name), 0))

    compilation = quote do
      @zigler_app unquote(zigler_app)
      @zig_version unquote(zig_version)
      @zig_resources unquote(zig_resources)

      @zig_code unquote(code.code)
      @zig_specs unquote(code_spec)
      @zig_src_dir unquote(src_dir)

      unquote_splicing(empty_functions)
    end

    test_list = Enum.map(code.tests, &{&1.title, &1.name})

    in_ex_unit = Application.started_applications
    |> Enum.any?(fn {app, _, _} -> app == :ex_unit end)

    test = make_code(__CALLER__.module, __CALLER__.file, test_list , in_ex_unit)

    [compilation, test]
  end

  defp make_code(module, file, tests, true) do
    quote bind_quoted: [module: module, file: file, tests: tests] do
      # register our tests.
      env = __ENV__
      for {name, test} <- Zigler.Unit.__zigtests__(module, tests) do
        @file file
        test_name = ExUnit.Case.register_test(env, :zigtest, name, [])
        def unquote(test_name)(_), do: unquote(test)
      end
    end
  end
  # for testing purposes only:
  defp make_code(module, _, tests, false) do
    quote bind_quoted: [module: module, tests: tests] do
      # register our tests.
      for {name, test} <- Zigler.Unit.__zigtests__(module, tests) do
        test_name = name |> string_to_hash |> String.to_atom
        def unquote(test_name)(_), do: unquote(test)
      end
    end
  end

  def __zigtests__(module, tests) do
    Enum.map(tests, fn
      {title, name} -> {title, test_content(module, name)}
    end)
  end

  defp test_content(module, name) do
    atom_name = name
    |> String.split(".")
    |> List.last
    |> String.to_atom

    quote do
      try do
        apply(unquote(module), unquote(atom_name), [])
        :ok
      rescue
        e in ErlangError ->
          error = [
            message: "Zig test failed",
            doctest: ExUnit.AssertionError.no_value(),
            expr: ExUnit.AssertionError.no_value(),
            left: ExUnit.AssertionError.no_value(),
            right: ExUnit.AssertionError.no_value()
          ]
          reraise ExUnit.AssertionError, error, __STACKTRACE__
      end
    end
  end

end
