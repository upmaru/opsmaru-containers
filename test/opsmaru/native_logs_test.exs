defmodule Opsmaru.Containers.Native.LogsTest do
  use ExUnit.Case, async: true

  alias Elixir.Plug.{Conn, Test}
  alias Opsmaru.Containers.Docker.{Plug, Raw}
  alias Opsmaru.Containers.Native.{Container, LogRecord, Logs}
  alias Opsmaru.Containers.TestSupport.{EngineFixture, ScriptedIncus}
  alias Opsmaru.Containers.Transport.Stream

  @web "aaaa1111" <> String.duplicate("1", 56)
  @job "bbbb2222" <> String.duplicate("2", 56)
  @quiet "cccc3333" <> String.duplicate("3", 56)
  @web_instance "oc-aaaa11111111"
  @job_instance "oc-bbbb22222222"
  @record "/.opsmaru/state/run.json"
  @t 1_795_000_000_000_000_000

  defmodule Socket do
    @moduledoc false
    @behaviour Opsmaru.Containers.Transport.Stream

    @impl true
    def recv(socket, _limit, deadline) do
      case :gen_tcp.recv(socket, 0, max(deadline - System.monotonic_time(:millisecond), 1)) do
        {:ok, bytes} -> {:ok, bytes}
        {:error, :closed} -> :eof
        error -> error
      end
    end

    @impl true
    def send(socket, bytes, _deadline), do: :gen_tcp.send(socket, bytes)

    @impl true
    def shutdown_write(socket, _deadline), do: :gen_tcp.shutdown(socket, :write)

    @impl true
    def close(socket), do: :gen_tcp.close(socket)
  end

  setup do
    engine = EngineFixture.start()

    native =
      ScriptedIncus.target(
        instances: [
          instance(@web, "web", "Stopped", %{}),
          instance(@job, "job", "Stopped", %{}),
          instance(@quiet, "quiet", "Stopped", %{"LogConfig" => %{"Type" => "none"}})
        ],
        files: %{
          {@web_instance, log(1)} =>
            file([
              rec(:stdout, 1, @t, "one\n"),
              rec(:stderr, 1, @t + 1_000_000_000, "two\n")
            ]),
          {@web_instance, log(2)} => file([rec(:stdout, 1, @t + 2_500_000_000, "three\n")]),
          {@web_instance, @record} => run_record(1, 0)
        }
      )

    context = EngineFixture.context(engine)
    target = %{context.target | native: native}
    context = %{context | target: target, capabilities: %{context.capabilities | target: target}}
    %{context: context, native: native}
  end

  describe "logs" do
    test "streams every record across files as Docker's multiplexed stream", %{
      context: context
    } do
      conn = logs(context, "web", "stdout=1&stderr=1")
      assert conn.status == 200

      assert Conn.get_resp_header(conn, "content-type") == [
               "application/vnd.docker.multiplexed-stream"
             ]

      assert frames(conn.resp_body) == [{1, "one\n"}, {2, "two\n"}, {1, "three\n"}]
      assert_received {:incus, {:sftp_open, @web_instance}}
      assert_received {:incus, {:sftp_close, @web_instance}}
    end

    test "selects streams and prefixes RFC 3339 timestamps with nine digits", %{
      context: context
    } do
      assert frames(logs(context, "web", "stderr=1").resp_body) == [{2, "two\n"}]

      assert frames(logs(context, "web", "stdout=1&timestamps=1").resp_body) == [
               {1, Logs.timestamp(@t) <> " one\n"},
               {1, Logs.timestamp(@t + 2_500_000_000) <> " three\n"}
             ]

      assert Logs.timestamp(@t + 5) =~ ~r/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.000000005Z\z/
    end

    test "filters by since and until, and tails records from the end", %{context: context} do
      seconds = div(@t, 1_000_000_000)

      assert frames(logs(context, "web", "stdout=1&stderr=1&since=#{seconds + 1}").resp_body) ==
               [{2, "two\n"}, {1, "three\n"}]

      assert frames(logs(context, "web", "stdout=1&stderr=1&until=#{seconds}.5").resp_body) ==
               [{1, "one\n"}]

      assert frames(logs(context, "web", "stdout=1&stderr=1&tail=2").resp_body) ==
               [{2, "two\n"}, {1, "three\n"}]

      # The tail counts records of both streams, then the stream filter applies.
      assert frames(logs(context, "web", "stdout=1&tail=2").resp_body) == [{1, "three\n"}]
      assert frames(logs(context, "web", "stdout=1&stderr=1&tail=0").resp_body) == []

      assert frames(logs(context, "web", "stdout=1&stderr=1&tail=all").resp_body) |> length() ==
               3
    end

    test "a position older than the oldest kept file continues from the oldest", %{
      context: context,
      native: native
    } do
      ScriptedIncus.update(native, fn state ->
        %{state | files: Map.delete(state.files, {@web_instance, log(1)})}
      end)

      assert frames(logs(context, "web", "stdout=1&stderr=1").resp_body) == [{1, "three\n"}]
    end

    test "refuses details, the none driver, no stream and malformed logs", %{
      context: context,
      native: native
    } do
      assert {400, ~s({"message":"native engine cannot honour: details"})} =
               status(logs(context, "web", "stdout=1&details=1"))

      assert {501, ~s({"message":"configured logging driver does not support reading"})} =
               status(logs(context, "quiet", "stdout=1"))

      assert {400, ~s({"message":"Bad parameters: you must choose at least one stream"})} =
               status(logs(context, "web", ""))

      assert {400, _} = status(logs(context, "web", "stdout=1&since=yesterday"))

      ScriptedIncus.update(native, &ScriptedIncus.put_file(&1, @web_instance, log(1), "JUNK"))

      assert {500, ~s({"message":"native engine: the logs of container #{@web} are malformed"})} ==
               status(logs(context, "web", "stdout=1"))
    end

    test "follow reads while the instance runs, then once more after it stops", %{
      context: context,
      native: native
    } do
      ScriptedIncus.update(native, &ScriptedIncus.put_status(&1, @web_instance, "Running"))
      task = Task.async(fn -> logs(context, "web", "stdout=1&stderr=1&follow=1") end)
      Process.sleep(350)
      assert Task.yield(task, 0) == nil

      append(native, @web_instance, log(2), [rec(:stdout, 1, @t + 3_000_000_000, "four\n")])
      Process.sleep(350)

      # Written in the instant before the exit: only the read after the stop sees it.
      ScriptedIncus.update(native, fn state ->
        state
        |> put_log(@web_instance, log(3), file([rec(:stderr, 1, @t + 4_000_000_000, "five\n")]))
        |> ScriptedIncus.put_status(@web_instance, "Stopped")
      end)

      conn = Task.await(task)

      assert frames(conn.resp_body) == [
               {1, "one\n"},
               {2, "two\n"},
               {1, "three\n"},
               {1, "four\n"},
               {2, "five\n"}
             ]

      opens = for {:incus, {:sftp_open, @web_instance}} <- messages(), do: :open
      assert length(opens) == 2
    end

    test "follow closes its session once the run finishes, before the instance stops", %{
      context: context,
      native: native
    } do
      # A held SFTP session keeps Incus from completing the stop.
      ScriptedIncus.update(native, fn state ->
        state
        |> ScriptedIncus.put_file(@web_instance, @record, run_record(2, nil))
        |> ScriptedIncus.put_status(@web_instance, "Running")
      end)

      task = Task.async(fn -> logs(context, "web", "stdout=1&follow=1") end)
      Process.sleep(350)
      assert Task.yield(task, 0) == nil
      assert {:incus, {:sftp_open, @web_instance}} in messages()

      ScriptedIncus.update(native, fn state ->
        state
        |> put_log(@web_instance, log(3), file([rec(:stdout, 2, @t + 4_000_000_000, "last\n")]))
        |> ScriptedIncus.put_file(@web_instance, @record, run_record(2, 0))
      end)

      Process.sleep(500)
      assert Task.yield(task, 0) == nil
      held = messages()
      assert {:incus, {:sftp_close, @web_instance}} in held
      refute {:incus, {:sftp_open, @web_instance}} in held

      ScriptedIncus.update(native, &ScriptedIncus.put_status(&1, @web_instance, "Stopped"))
      conn = Task.await(task)

      assert frames(conn.resp_body) == [{1, "one\n"}, {1, "three\n"}, {1, "last\n"}]
    end

    test "follow on a stopped container answers what is written and ends", %{context: context} do
      conn = logs(context, "web", "stdout=1&follow=1")
      assert frames(conn.resp_body) == [{1, "one\n"}, {1, "three\n"}]
    end
  end

  describe "attach" do
    test "serves the next run's output from its first record", %{
      context: context,
      native: native
    } do
      ScriptedIncus.update(native, fn state ->
        state
        |> put_log(@job_instance, log(1), file([rec(:stdout, 1, @t, "old run\n")]))
        |> ScriptedIncus.put_file(@job_instance, @record, run_record(1, 0))
      end)

      assert {:upgrade, response, stream, ""} =
               attach(context, "job", "stream=1&stdout=1&stderr=1")

      assert response.status == 101

      assert {"content-type", "application/vnd.docker.multiplexed-stream"} in response.headers

      # The end of the logs was noted and the session closed before the start.
      assert_received {:incus, {:sftp_close, @job_instance}}

      # The run starts, prints and exits between two polls.
      ScriptedIncus.update(native, fn state ->
        state
        |> put_log(
          @job_instance,
          log(1),
          file([
            rec(:stdout, 1, @t, "old run\n"),
            rec(:stdout, 2, @t + 1, "hello\n"),
            rec(:stderr, 2, @t + 2, "world\n")
          ])
        )
        |> ScriptedIncus.put_file(@job_instance, @record, run_record(2, 0))
      end)

      assert frames(drain(stream)) == [{1, "hello\n"}, {2, "world\n"}]
    end

    test "follows a run that is already going until the instance stops", %{
      context: context,
      native: native
    } do
      ScriptedIncus.update(native, fn state ->
        state
        |> put_log(@job_instance, log(1), file([rec(:stdout, 1, @t, "before\n")]))
        |> ScriptedIncus.put_file(@job_instance, @record, run_record(1, nil))
        |> ScriptedIncus.put_status(@job_instance, "Running")
      end)

      assert {:upgrade, _, stream, ""} = attach(context, "job", "stream=1&stdout=1")

      append(native, @job_instance, log(1), [rec(:stdout, 1, @t + 1, "after\n")])
      Process.sleep(250)

      ScriptedIncus.update(native, fn state ->
        state
        |> ScriptedIncus.put_file(@job_instance, @record, run_record(1, 0))
        |> ScriptedIncus.put_status(@job_instance, "Stopped")
      end)

      assert frames(drain(stream)) == [{1, "after\n"}]
    end

    test "closes its session once the awaited run finishes, before the instance stops", %{
      context: context,
      native: native
    } do
      ScriptedIncus.update(native, fn state ->
        state
        |> put_log(@job_instance, log(1), file([rec(:stdout, 1, @t, "before\n")]))
        |> ScriptedIncus.put_file(@job_instance, @record, run_record(1, nil))
        |> ScriptedIncus.put_status(@job_instance, "Running")
      end)

      assert {:upgrade, _, stream, ""} = attach(context, "job", "stream=1&stdout=1")

      ScriptedIncus.update(native, fn state ->
        state
        |> put_log(
          @job_instance,
          log(1),
          file([rec(:stdout, 1, @t, "before\n"), rec(:stdout, 1, @t + 1, "after\n")])
        )
        |> ScriptedIncus.put_file(@job_instance, @record, run_record(1, 0))
      end)

      Process.sleep(500)

      # The reading session closed and none opened again while the instance runs.
      held = messages()

      sessions =
        for {:incus, {call, @job_instance}} <- held, call in [:sftp_open, :sftp_close], do: call

      assert :sftp_open in sessions
      assert List.last(sessions) == :sftp_close

      ScriptedIncus.update(native, &ScriptedIncus.put_status(&1, @job_instance, "Stopped"))
      assert frames(drain(stream)) == [{1, "after\n"}]
    end

    test "a run recorded right after a stale stopped read does not end the attach", %{
      context: context,
      native: native
    } do
      ScriptedIncus.update(native, fn state ->
        state
        |> put_log(@job_instance, log(1), file([rec(:stdout, 1, @t, "old run\n")]))
        |> ScriptedIncus.put_file(@job_instance, @record, run_record(1, 0))
      end)

      assert {:upgrade, _, stream, ""} = attach(context, "job", "stream=1&stdout=1")

      # The start is in flight and reads as stopped; the run starts, prints
      # and exits right after that read.
      ScriptedIncus.update(native, fn state ->
        %{
          state
          | after_state: fn state ->
              %{state | after_state: & &1}
              |> put_log(
                @job_instance,
                log(1),
                file([rec(:stdout, 1, @t, "old run\n"), rec(:stdout, 2, @t + 1, "hello\n")])
              )
              |> ScriptedIncus.put_file(@job_instance, @record, run_record(2, 0))
              |> ScriptedIncus.put_status(@job_instance, "Running")
            end
        }
      end)

      refute until_end(stream, now() + 500) == :eof

      ScriptedIncus.update(native, &ScriptedIncus.put_status(&1, @job_instance, "Stopped"))
      early = for {:early, bytes} <- messages(), into: "", do: bytes
      assert frames(early <> drain(stream)) == [{1, "hello\n"}]
    end

    test "refuses stdin, logs and a request without stream", %{context: context} do
      for {query, refused} <- [
            {"stream=1&stdin=1&stdout=1", "stdin attach"},
            {"stream=1&logs=1&stdout=1", "attach logs"},
            {"stdout=1", "attach without stream"}
          ] do
        assert {:http, 501, _, body} = attach(context, "job", query)
        assert Jason.decode!(body) == %{"message" => "native engine cannot honour: " <> refused}
      end
    end

    test "the raw adapter relays attach to the client with half-close", %{
      context: context,
      native: native
    } do
      {:ok, listener} =
        :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, exit_on_close: false])

      {:ok, port} = :inet.port(listener)
      {:ok, client} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
      {:ok, server} = :gen_tcp.accept(listener)

      relay =
        Task.async(fn ->
          request = attach_request(context, "job", "stream=1&stdout=1")

          Raw.relay(EngineFixture.AllowHost, request, tcp_stream(server),
            admission_deadline: deadline(),
            deadline: deadline(),
            request_tail: ""
          )
        end)

      {:ok, head} = :gen_tcp.recv(client, 0, 2_000)
      assert head =~ "HTTP/1.1 101 UPGRADED"
      assert head =~ "content-type: application/vnd.docker.multiplexed-stream"

      # The client sends nothing and half-closes, as `docker run` does.
      :ok = :gen_tcp.shutdown(client, :write)

      ScriptedIncus.update(native, fn state ->
        state
        |> put_log(@job_instance, log(1), file([rec(:stdout, 1, @t, "hi\n")]))
        |> ScriptedIncus.put_file(@job_instance, @record, run_record(1, 0))
      end)

      assert frames(recv_all(client)) == [{1, "hi\n"}]
      assert {:relayed, :ok} = Task.await(relay)
    end
  end

  # -- Helpers --------------------------------------------------------------------

  defp logs(context, name, query) do
    "GET"
    |> Test.conn("/containers/#{name}/logs?" <> query)
    |> Conn.put_private(:opsmaru_containers_peer, {context, self()})
    |> Plug.call(Plug.init(host: EngineFixture.AllowHost, stream_timeout: 5_000))
  end

  defp status(conn), do: {conn.status, conn.resp_body}

  defp attach(context, name, query) do
    Raw.open(EngineFixture.AllowHost, attach_request(context, name, query),
      admission_deadline: deadline(),
      deadline: deadline()
    )
  end

  defp attach_request(context, name, query) do
    %{
      method: "POST",
      path: "/containers/#{name}/attach",
      query: query,
      peer: {127, 0, 0, 1},
      host_peer: {context, self()},
      headers: [{"upgrade", "tcp"}, {"connection", "Upgrade"}],
      body: ""
    }
  end

  # Reads until the stream ends or the deadline passes, keeping what it read
  # for a later `drain/1`, and returns how it stopped.
  defp until_end(stream, deadline) do
    case Stream.recv(stream, 65_536, deadline) do
      {:ok, bytes} ->
        send(self(), {:early, bytes})
        until_end(stream, deadline)

      other ->
        other
    end
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp drain(stream, acc \\ "") do
    case Stream.recv(stream, 65_536, deadline()) do
      {:ok, bytes} -> drain(stream, acc <> bytes)
      :eof -> acc
    end
  end

  defp recv_all(socket, acc \\ "") do
    case :gen_tcp.recv(socket, 0, 3_000) do
      {:ok, bytes} -> recv_all(socket, acc <> bytes)
      {:error, :closed} -> acc
    end
  end

  defp tcp_stream(socket),
    do: %Stream{adapter: Socket, handle: socket}

  defp messages do
    receive do
      message -> [message | messages()]
    after
      0 -> []
    end
  end

  defp frames(<<stream, 0, 0, 0, size::32, data::binary-size(size), rest::binary>>),
    do: [{stream, data} | frames(rest)]

  defp frames(""), do: []

  defp log(number),
    do: "/.opsmaru/logs/" <> String.pad_leading(Integer.to_string(number), 10, "0") <> ".log"

  defp rec(stream, run, time, data),
    do: %LogRecord{stream: stream, run: run, time: time, data: data}

  defp file(records), do: LogRecord.magic() <> Enum.map_join(records, &LogRecord.encode/1)

  defp put_log(state, instance, path, content),
    do: ScriptedIncus.put_file(state, instance, path, content)

  defp append(native, instance, path, records) do
    ScriptedIncus.update(native, fn state ->
      current = Map.get(state.files, {instance, path}, LogRecord.magic())
      put_log(state, instance, path, current <> Enum.map_join(records, &LogRecord.encode/1))
    end)
  end

  defp run_record(run, code) do
    Jason.encode!(%{
      "version" => 1,
      "run" => run,
      "pid" => 5,
      "started_at" => "2026-11-27T10:00:00Z",
      "finished_at" => if(code, do: "2026-11-27T10:00:04Z"),
      "exit_code" => code,
      "signal" => nil,
      "oom_killed" => false,
      "error" => nil
    })
  end

  defp instance(id, name, status, host_config) do
    keys =
      Container.keys(%{
        id: id,
        name: name,
        created: DateTime.from_unix!(100),
        image_id: "sha256:" <> String.duplicate("b", 64),
        image_ref: "busybox",
        labels: %{},
        config: %{"Path" => "sh", "Args" => [], "HostConfig" => host_config},
        init: "digest",
        autoremove: false
      })

    %{"name" => Container.instance_name(id), "status" => status, "config" => keys}
  end

  defp deadline, do: System.monotonic_time(:millisecond) + 4_000
end
