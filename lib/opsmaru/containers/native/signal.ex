defmodule Opsmaru.Containers.Native.Signal do
  @moduledoc false
  # Docker's signal forms, as the shim parses them: `SIGHUP`, `HUP` (any
  # case) or a number from 1 to 64.

  @names ~w(ABRT ALRM BUS CHLD CONT FPE HUP ILL INT IO KILL PIPE PROF QUIT SEGV STOP SYS TERM
            TRAP TSTP TTIN TTOU URG USR1 USR2 VTALRM WINCH XCPU XFSZ)

  @doc ~s(`{:ok, canonical}`, such as `"SIGHUP"` or `"34"`, or `:error`.)
  def parse(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number in 1..64 ->
        {:ok, if(number == 9, do: "SIGKILL", else: Integer.to_string(number))}

      {_, ""} ->
        :error

      _ ->
        name = value |> String.upcase() |> String.replace_prefix("SIG", "")
        if name in @names, do: {:ok, "SIG" <> name}, else: :error
    end
  end

  def parse(_), do: :error

  def kill?(value), do: parse(value) == {:ok, "SIGKILL"}
end
