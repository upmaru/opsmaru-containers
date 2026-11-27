defmodule Opsmaru.Containers.Docker.EngineRequest do
  @moduledoc false
  # One complete request to the nested engine, for the library's own reads
  # and merges. Client requests are relayed by the adapters instead.

  alias Opsmaru.Containers.Docker.HTTP
  alias Opsmaru.Containers.Transport
  alias Opsmaru.Containers.Transport.Stream

  @limit 4_194_304

  @spec call(map(), String.t(), String.t(), binary() | nil, integer(), pos_integer()) ::
          {:ok, pos_integer(), binary()} | {:error, term()}
  def call(context, method, target, body, deadline, limit \\ @limit) do
    with {:ok, stream} <- Transport.dial(context.dialer, context.target, deadline) do
      try do
        framing = if body, do: {:length, byte_size(body)}, else: :none
        headers = if body, do: [{"content-type", "application/json"}], else: []

        with :ok <- HTTP.send_head(stream, method, target, headers, framing, deadline),
             :ok <- if(body, do: HTTP.send_chunk(stream, body, framing, deadline), else: :ok),
             {:ok, response} <- HTTP.receive_head(stream, method, deadline),
             {:ok, data} <- HTTP.collect(response, limit) do
          {:ok, response.status, data}
        end
      after
        Stream.close(stream)
      end
    end
  end

  @doc "Like `call/6`, decoding a JSON body."
  def json(context, method, target, body, deadline, limit \\ @limit) do
    with {:ok, status, data} <- call(context, method, target, body, deadline, limit),
         {:ok, decoded} <- decode(data) do
      {:ok, status, decoded}
    end
  end

  defp decode(""), do: {:ok, nil}

  defp decode(data) do
    case Jason.decode(data) do
      {:ok, decoded} -> {:ok, decoded}
      _ -> {:error, :invalid_body}
    end
  end
end
