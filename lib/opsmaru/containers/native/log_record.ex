defmodule Opsmaru.Containers.Native.LogRecord do
  @moduledoc false
  # The shim's log files (design decision 8): the magic `OCL1`, then records
  # of an 18-byte header and 1 to 16 384 data bytes. They are written inside
  # the container, so they are decoded as bounded, untrusted input.

  import Bitwise

  @magic "OCL1"
  @header 18
  @max_data 16_384
  @partial 1

  defstruct [:stream, :run, :time, :data, partial: false]

  @type t :: %__MODULE__{
          stream: :stdout | :stderr,
          run: non_neg_integer(),
          time: integer(),
          data: binary(),
          partial: boolean()
        }

  def magic, do: @magic
  def header_size, do: @header
  def max_data, do: @max_data

  @doc """
  Decodes a whole log file: `{:ok, records, rest}` or `{:error, :malformed}`.
  A trailing incomplete record (or magic) is the shim still writing, and
  `rest` holds it for the next read.
  """
  def decode_file(<<@magic, rest::binary>>), do: decode(rest)

  def decode_file(bytes) when byte_size(bytes) < 4 do
    if String.starts_with?(@magic, bytes), do: {:ok, [], bytes}, else: {:error, :malformed}
  end

  def decode_file(_), do: {:error, :malformed}

  @doc """
  Decodes records from a position after the magic. Returns
  `{:ok, records, rest}`, where `rest` is an incomplete trailing record, or
  `{:error, :malformed}` at the first record that is not valid.
  """
  def decode(bytes), do: decode(bytes, [])

  defp decode(
         <<stream, flags, run::32, time::signed-64, length::32, rest::binary>> = bytes,
         records
       ) do
    cond do
      stream not in [1, 2] or (flags &&& bnot(@partial)) != 0 or length not in 1..@max_data ->
        {:error, :malformed}

      byte_size(rest) < length ->
        {:ok, Enum.reverse(records), bytes}

      true ->
        <<data::binary-size(length), rest::binary>> = rest

        record = %__MODULE__{
          stream: if(stream == 1, do: :stdout, else: :stderr),
          run: run,
          time: time,
          data: data,
          partial: (flags &&& @partial) == @partial
        }

        decode(rest, [record | records])
    end
  end

  defp decode(rest, records), do: {:ok, Enum.reverse(records), rest}

  @doc "Encodes a record, as the shim does. For tests and fixtures."
  def encode(%__MODULE__{} = record) do
    stream = if record.stream == :stdout, do: 1, else: 2
    flags = if record.partial, do: @partial, else: 0

    <<stream, flags, record.run::32, record.time::signed-64, byte_size(record.data)::32,
      record.data::binary>>
  end
end
