defmodule Opsmaru.Containers.Docker.HTTP do
  @moduledoc false

  alias Opsmaru.Containers.Transport.Stream

  @read_bytes 16_384
  @header_bytes 65_536
  @hop_headers ~w(connection keep-alive proxy-authenticate proxy-authorization proxy-connection
                  te trailer transfer-encoding upgrade)

  defstruct [:stream, :deadline, :status, :headers, :mode, buffer: ""]

  def send_head(stream, method, target, headers, framing, deadline, protocol \\ nil) do
    headers = end_to_end(headers)
    host = Enum.find(headers, {"host", "docker"}, fn {name, _} -> name == "host" end)

    headers =
      Enum.reject(headers, fn {name, _} -> name in ["content-length", "expect", "host"] end)

    headers = [host | connection_headers(protocol)] ++ headers ++ length_headers(framing)

    if Enum.all?(headers, &valid_header?/1) do
      Stream.send(
        stream,
        [method, " ", target, " HTTP/1.1\r\n", encode_headers(headers), "\r\n"],
        deadline
      )
    else
      {:error, :invalid_headers}
    end
  end

  def send_chunk(stream, bytes, {:length, _}, deadline), do: Stream.send(stream, bytes, deadline)
  def send_chunk(_, "", :chunked, _), do: :ok

  def send_chunk(stream, bytes, :chunked, deadline) do
    Stream.send(
      stream,
      [Integer.to_string(byte_size(bytes), 16), "\r\n", bytes, "\r\n"],
      deadline
    )
  end

  def finish(stream, :chunked, deadline), do: Stream.send(stream, "0\r\n\r\n", deadline)
  def finish(_, _, _), do: :ok

  def receive_head(stream, method, deadline, takeover \\ nil) do
    %__MODULE__{stream: stream, deadline: deadline}
    |> head(method, takeover, 0)
  end

  def upgrade_protocol(headers) do
    with [protocol] <- tokens(headers, "upgrade"),
         true <- "upgrade" in tokens(headers, "connection") do
      protocol
    else
      _ -> nil
    end
  end

  def raw_head(%{status: status, headers: headers}) do
    status_line = if status == 101, do: "HTTP/1.1 101 UPGRADED\r\n", else: "HTTP/1.1 200 OK\r\n"

    [status_line, encode_headers(headers), "\r\n"]
  end

  defp connection_headers(nil), do: [{"connection", "close"}]
  defp connection_headers(protocol), do: [{"connection", "Upgrade"}, {"upgrade", protocol}]

  def end_to_end(headers) do
    named = tokens(headers, "connection")
    Enum.reject(headers, fn {name, _} -> name in @hop_headers or name in named end)
  end

  defp tokens(headers, key) do
    for {^key, value} <- headers, token <- String.split(value, ",") do
      token |> String.trim() |> String.downcase(:ascii)
    end
  end

  defp length_headers(:chunked), do: [{"transfer-encoding", "chunked"}]
  defp length_headers({:length, length}), do: [{"content-length", Integer.to_string(length)}]
  defp length_headers(:none), do: []

  defp encode_headers(headers) do
    Enum.map(headers, fn {name, value} -> [name, ": ", value, "\r\n"] end)
  end

  defp head(_, _, _, count) when count >= 8, do: {:error, :invalid_head}

  defp head(response, method, takeover, count) do
    with {:ok, header, response} <- delimited(response, "\r\n\r\n", @header_bytes),
         [status_line | lines] <- :binary.split(header, "\r\n", [:global]),
         {:ok, status} <- status(status_line),
         {:ok, headers} <- parse_headers(lines) do
      decoded_head(response, method, takeover, count, status, headers)
    else
      _ -> {:error, :invalid_head}
    end
  end

  defp decoded_head(response, method, takeover, count, status, _headers)
       when status in 100..199 and status != 101,
       do: head(response, method, takeover, count + 1)

  defp decoded_head(response, method, takeover, _count, status, headers) do
    with {:ok, mode} <- body_mode(method, status, headers, takeover) do
      {:ok, %{response | status: status, headers: headers, mode: mode}}
    end
  end

  defp status(<<"HTTP/1.", version, " ", a, b, c, rest::binary>>)
       when version in [?0, ?1] and a in ?1..?5 and b in ?0..?9 and c in ?0..?9 do
    if rest == "" or match?(<<" ", _::binary>>, rest),
      do: {:ok, (a - ?0) * 100 + (b - ?0) * 10 + c - ?0},
      else: {:error, :invalid_status}
  end

  defp status(_), do: {:error, :invalid_status}

  defp parse_headers(lines) do
    Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, acc} ->
      with [name, value] <- :binary.split(line, ":"),
           pair = {String.downcase(name, :ascii), trim_whitespace(value)},
           true <- valid_header?(pair) do
        {:cont, {:ok, [pair | acc]}}
      else
        _ -> {:halt, {:error, :invalid_headers}}
      end
    end)
    |> case do
      {:ok, headers} -> {:ok, Enum.reverse(headers)}
      error -> error
    end
  end

  defp trim_whitespace(value), do: Regex.replace(~r/\A[ \t]+|[ \t]+\z/, value, "")

  defp valid_header?({name, value}) do
    Regex.match?(~r/\A[!#$%&'*+.^_`|~0-9a-z-]+\z/, name) and
      not Regex.match?(~r/[\x00-\x08\x0a-\x1f\x7f]/, value)
  end

  defp body_mode("HEAD", _, _, _), do: {:ok, :complete}
  defp body_mode(_, status, _, _) when status in [204, 304], do: {:ok, :complete}

  defp body_mode(_, 101, headers, {_mode, protocol}) when is_binary(protocol) do
    if upgrade_protocol(headers) == protocol and unframed?(headers),
      do: {:ok, {:raw, protocol}},
      else: {:error, :unexpected_upgrade}
  end

  defp body_mode(_, 101, _, _), do: {:error, :unexpected_upgrade}

  defp body_mode(_, 200, headers, {"docker_stream", nil}) do
    if values(headers, "content-type") == ["application/vnd.docker.raw-stream"] and
         unframed?(headers),
       do: {:ok, {:raw, nil}},
       else: body_framing(headers)
  end

  defp body_mode(_, _, headers, _), do: body_framing(headers)

  defp unframed?(headers) do
    values(headers, "transfer-encoding") == [] and values(headers, "content-length") == []
  end

  defp body_framing(headers) do
    case {tokens(headers, "transfer-encoding"), values(headers, "content-length")} do
      {["chunked"], []} -> {:ok, :chunk_size}
      {[], []} -> {:ok, :eof}
      {[], [value]} -> content_length(value)
      _ -> {:error, :invalid_framing}
    end
  end

  defp values(headers, name), do: for({^name, value} <- headers, do: value)

  defp content_length(value) do
    with true <- Regex.match?(~r/\A[0-9]{1,19}\z/, value),
         {length, ""} <- Integer.parse(value) do
      {:ok, {:length, length}}
    else
      _ -> {:error, :invalid_framing}
    end
  end

  def next(%{mode: mode}) when mode in [:complete, {:length, 0}], do: :eof

  def next(%{mode: {:chunk, 0}} = response), do: next(%{response | mode: :chunk_end})
  def next(%{mode: {:length, length}} = response), do: take_body(response, length, :length)
  def next(%{mode: {:chunk, size}} = response), do: take_body(response, size, :chunk)

  def next(%{mode: :chunk_size} = response) do
    with {:ok, size_line, response} <- delimited(response, "\r\n", 1_024),
         [size | _] <- :binary.split(size_line, ";"),
         true <- Regex.match?(~r/\A[0-9a-fA-F]{1,16}\z/, size),
         {count, ""} <- Integer.parse(size, 16) do
      if count == 0,
        do: end_chunks(response, @header_bytes),
        else: next(%{response | mode: {:chunk, count}})
    else
      _ -> {:error, :invalid_framing}
    end
  end

  def next(%{mode: :chunk_end} = response) do
    case delimited(response, "\r\n", 0) do
      {:ok, "", response} -> next(%{response | mode: :chunk_size})
      _ -> {:error, :invalid_framing}
    end
  end

  def next(%{mode: :eof, buffer: ""} = response) do
    case fill(response) do
      {:ok, response} -> next(response)
      other -> other
    end
  end

  def next(%{mode: :eof, buffer: bytes} = response),
    do: {:ok, bytes, %{response | buffer: ""}}

  def collect(response, limit), do: collect(response, [], limit)

  defp collect(response, chunks, remaining) do
    case next(response) do
      {:ok, bytes, response} when byte_size(bytes) <= remaining ->
        collect(response, [bytes | chunks], remaining - byte_size(bytes))

      :eof ->
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

      _ ->
        {:error, :invalid_body}
    end
  end

  defp end_chunks(response, remaining) do
    case delimited(response, "\r\n", remaining - 2) do
      {:ok, "", _} -> :eof
      {:ok, field, response} -> end_chunks(response, remaining - byte_size(field) - 2)
      _ -> {:error, :invalid_framing}
    end
  end

  defp take_body(%{buffer: ""} = response, length, mode) do
    case fill(response) do
      {:ok, response} -> take_body(response, length, mode)
      _ -> {:error, :truncated_body}
    end
  end

  defp take_body(%{buffer: buffer} = response, length, mode) do
    size = min(length, byte_size(buffer))
    <<bytes::binary-size(size), rest::binary>> = buffer
    {:ok, bytes, %{response | mode: {mode, length - size}, buffer: rest}}
  end

  defp delimited(%{buffer: buffer} = response, separator, limit) do
    case :binary.match(buffer, separator) do
      {offset, length} when offset <= limit ->
        <<part::binary-size(offset), _::binary-size(length), rest::binary>> = buffer
        {:ok, part, %{response | buffer: rest}}

      :nomatch when byte_size(buffer) < limit + byte_size(separator) ->
        with {:ok, response} <- fill(response), do: delimited(response, separator, limit)

      _ ->
        {:error, :frame_limit}
    end
  end

  defp fill(response) do
    case Stream.recv(response.stream, @read_bytes, response.deadline) do
      {:ok, chunk} when is_binary(chunk) and byte_size(chunk) in 1..@read_bytes ->
        {:ok, %{response | buffer: response.buffer <> chunk}}

      :eof ->
        :eof

      _ ->
        {:error, :stream_read}
    end
  end
end
