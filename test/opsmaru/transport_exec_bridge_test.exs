defmodule Opsmaru.Containers.Transport.ExecBridgeTest do
  use ExUnit.Case, async: true

  alias Opsmaru.Containers.Nested.Target
  alias Opsmaru.Containers.TestSupport.FakeExecIncus, as: Fake
  alias Opsmaru.Containers.Transport.{ExecBridge, Stream}
  alias Opsmaru.Incus

  @helper "/usr/local/libexec/opsmaru/exec-socket-bridge"
  @socket "/var/run/docker.sock"

  defp target(opts \\ []) do
    connection =
      Incus.Connection.unix!(
        "/unused",
        [owner: :fixture, project: "fixtures"] ++ Keyword.take(opts, [:max_stream_bytes])
      )

    client = %Incus{
      connection: connection,
      context: Incus.Context.new!(owner: :fixture, identity: :host, ready?: fn -> true end),
      server: nil
    }

    %Target{client: client, instance: "engine"}
  end

  defp options(extra \\ %{}),
    do: Map.merge(%{helper: @helper, socket: @socket, incus: Fake}, Map.new(extra))

  defp deadline(ms \\ 2_000), do: System.monotonic_time(:millisecond) + ms

  defp open(session, extra \\ %{}, target \\ target()) do
    Fake.use_session(session)
    ExecBridge.dial(target, options(extra), deadline())
  end

  defp connected(output, extra \\ %{}, fake_opts \\ []) do
    session = Fake.start(self(), fake_opts)
    Fake.push(session, "1", {:binary, "OCB1" <> output})
    {:ok, %Stream{adapter: ExecBridge, handle: handle}} = open(session, extra)
    assert_received {:incus, {:exec, _, _, _}}
    {session, handle}
  end

  describe "options" do
    test "invalid options fail before any exec is created" do
      session = Fake.start(self())
      Fake.use_session(session)

      invalid = [
        %{socket: @socket, incus: Fake},
        %{helper: "relative/helper", socket: @socket, incus: Fake},
        options(socket: "/var/run/\0docker.sock"),
        options(helper: :helper),
        options(unknown: true),
        options(keepalive_interval: 0),
        options(keepalive_interval: 3_600_001),
        options(keepalive_interval: 1.5),
        options(observer: :not_a_pid),
        options(limits: %{max_input_bytes: 0}),
        options(limits: %{max_output_bytes: -1}),
        options(limits: %{max_bytes: 10}),
        options(limits: :unbounded),
        options(request_context: %{timeout: 1_000}),
        options(incus: nil),
        [helper: @helper, helper: @helper, socket: @socket, incus: Fake],
        [{"helper", @helper}],
        :invalid
      ]

      for options <- invalid do
        assert ExecBridge.dial(target(), options, deadline()) == {:error, :invalid_options},
               "accepted #{inspect(options)}"
      end

      refute_received {:incus, _}
    end

    test "keyword options are accepted and the exec runs the helper non-interactively" do
      session = Fake.start(self())
      Fake.push(session, "1", {:binary, "OCB1"})
      Fake.use_session(session)
      target = target()

      assert {:ok, %Stream{adapter: ExecBridge}} =
               ExecBridge.dial(
                 target,
                 [helper: @helper, socket: @socket, incus: Fake, limits: [max_input_bytes: 1]],
                 deadline()
               )

      assert_received {:incus, {:exec, client, "engine", request}}
      assert client == target.client

      assert request == %{
               "command" => [@helper, @socket],
               "interactive" => false,
               "wait-for-websocket" => true,
               "record-output" => false
             }
    end

    test "a supplied request context is bound to the exec client" do
      session = Fake.start(self())
      Fake.push(session, "1", {:binary, "OCB1"})
      context = Incus.RequestContext.new!(timeout: 60_000)

      assert {:ok, _} = open(session, %{request_context: context})
      assert_received {:incus, {:exec, client, _, _}}
      assert client.connection.request_context == context
    end

    test "an exec failure is returned without retrying" do
      Fake.fail_exec(%Incus.Error{kind: :forbidden})

      assert {:error, {:exec, %Incus.Error{kind: :forbidden}}} =
               ExecBridge.dial(target(), options(), deadline())
    end
  end

  describe "handshake and frames" do
    test "a header split across output chunks is accepted" do
      session = Fake.start(self())
      Fake.push(session, "1", {:binary, "OC"})
      Fake.push(session, "1", {:binary, "B1" <> Fake.frame("hi")})
      assert {:ok, %Stream{handle: handle}} = open(session)
      assert ExecBridge.recv(handle, 1_024, deadline()) == {:ok, "hi"}
    end

    test "a bad header fails the dial and terminates the helper" do
      session = Fake.start(self())
      Fake.push(session, "1", {:binary, "HTTP"})

      assert {:error, {:bridge_handshake, {:ok, "HTTP"}}} = open(session)
      assert_received {:incus, :completed?}
      assert_received {:incus, {:signal, 15}}
      assert_received {:incus, {:wait, 3_000}}
      assert_received {:incus, :close}
    end

    test "output closing before the header fails the dial" do
      session = Fake.start(self())
      Fake.push(session, "1", :closed)
      assert {:error, {:bridge_handshake, {:error, {:exec_channel, :closed}}}} = open(session)
      assert_received {:incus, :close}
    end

    test "data frames split at the read limit and the EOF frame ends output" do
      output = Fake.frame("hello") <> Fake.frame("world!") <> Fake.eof_frame()
      {_session, handle} = connected(output)

      assert ExecBridge.recv(handle, 3, deadline()) == {:ok, "hel"}
      assert ExecBridge.recv(handle, 3, deadline()) == {:ok, "lo"}
      assert ExecBridge.recv(handle, 3, deadline()) == {:ok, "wor"}
      assert ExecBridge.recv(handle, 3, deadline()) == {:ok, "ld!"}
      assert ExecBridge.recv(handle, 3, deadline()) == :eof
      assert ExecBridge.recv(handle, 3, deadline()) == :eof
    end

    test "frames arriving in pieces decode as one" do
      session = Fake.start(self())
      <<a::binary-size(6), b::binary>> = "OCB1" <> Fake.frame("abcdef")
      Fake.push(session, "1", {:binary, a})
      Fake.push(session, "1", {:binary, b})
      assert {:ok, %Stream{handle: handle}} = open(session)
      assert ExecBridge.recv(handle, 1_024, deadline()) == {:ok, "abcdef"}
    end

    test "an unknown type and out-of-range lengths are stream errors" do
      for frame <- [
            <<2, 0::32>>,
            <<0, 0::32>>,
            <<0, 16_385::32>>,
            <<1, 1::32>>
          ] do
        {_session, handle} = connected(frame)
        assert ExecBridge.recv(handle, 1_024, deadline()) == {:error, :invalid_bridge_frame}
      end
    end

    test "a full 16 KiB data frame is accepted" do
      bytes = :binary.copy("x", 16_384)
      {_session, handle} = connected(Fake.frame(bytes))
      assert ExecBridge.recv(handle, 65_536, deadline()) == {:ok, bytes}
    end

    test "output ending without the EOF frame is a failure, not EOF" do
      {session, handle} = connected("", %{observer: self()})
      Fake.push(session, "1", :closed)

      assert ExecBridge.recv(handle, 1_024, deadline()) ==
               {:error, {:exec_channel, :closed}}

      assert_received {:bridge_output, {:error, {:exec_channel, :closed}}}
    end

    test "recv honours the deadline" do
      {_session, handle} = connected("")
      assert ExecBridge.recv(handle, 1_024, deadline(50)) == {:error, :deadline}
    end
  end

  describe "stdin" do
    test "stdin is chunked at 16 KiB and shutdown_write closes input" do
      {_session, handle} = connected("")
      bytes = :crypto.strong_rand_bytes(40_000)

      assert ExecBridge.send(handle, [bytes], deadline()) == :ok
      assert_received {:incus, {:input, a}}
      assert_received {:incus, {:input, b}}
      assert_received {:incus, {:input, c}}
      assert Enum.map([a, b, c], &byte_size/1) == [16_384, 16_384, 7_232]
      assert a <> b <> c == bytes

      assert ExecBridge.shutdown_write(handle, deadline()) == :ok
      assert_received {:incus, :close_input}
    end

    test "an input failure is reported with the bytes already sent" do
      {_session, handle} =
        connected("", %{observer: self()},
          results: %{input: {:error, %Incus.Error{kind: :closed}}}
        )

      assert {:error, %Incus.Error{kind: :closed}} = ExecBridge.send(handle, "x", deadline())
      assert_received {:bridge_input, :closed, 0}
    end
  end

  describe "limits" do
    test "the input limit fails visibly instead of truncating" do
      {_session, handle} = connected("", %{limits: %{max_input_bytes: 10}})

      assert ExecBridge.send(handle, "123456", deadline()) == :ok
      assert_received {:incus, {:input, "123456"}}
      assert ExecBridge.send(handle, "12345", deadline()) == {:error, :input_limit}
      refute_received {:incus, {:input, _}}
    end

    test "the output limit fails visibly instead of truncating" do
      output = Fake.frame("12345") <> Fake.frame("6")
      {_session, handle} = connected(output, %{limits: %{max_output_bytes: 5}})

      assert ExecBridge.recv(handle, 1_024, deadline()) == {:ok, "12345"}
      assert ExecBridge.recv(handle, 1_024, deadline()) == {:error, :output_limit}
    end

    test "limits are capped by the connection's max_stream_bytes" do
      session = Fake.start(self())
      Fake.push(session, "1", {:binary, "OCB1"})

      assert {:ok, %Stream{handle: handle}} =
               open(
                 session,
                 %{limits: %{max_input_bytes: 1_000}},
                 target(max_stream_bytes: 8)
               )

      assert ExecBridge.send(handle, "12345678", deadline()) == :ok
      assert ExecBridge.send(handle, "9", deadline()) == {:error, :input_limit}
    end
  end

  describe "keepalive" do
    test "no pings run unless configured" do
      {_session, _handle} = connected("")
      refute_receive {:incus, {:ping, _}}, 100
    end

    test "pings stdout, stderr and control while the owner lives, and stop with it" do
      session = Fake.start(self())
      Fake.push(session, "1", {:binary, "OCB1"})
      test = self()

      owner =
        spawn(fn ->
          Fake.use_session(session)

          {:ok, _} =
            ExecBridge.dial(target(), options(keepalive_interval: 20), deadline())

          send(test, :dialed)
          Process.sleep(:infinity)
        end)

      assert_receive :dialed
      assert_receive {:incus, {:ping, "1"}}, 500
      assert_receive {:incus, {:ping, "2"}}, 500
      assert_receive {:incus, {:ping, "control"}}, 500

      Process.exit(owner, :kill)
      Process.sleep(40)
      flush_pings()
      refute_receive {:incus, {:ping, _}}, 100
    end

    test "a failed ping is reported to the observer" do
      {_session, _handle} =
        connected("", %{keepalive_interval: 10, observer: self()},
          results: %{ping: {:error, %Incus.Error{kind: :closed}}}
        )

      assert_receive {:bridge_keepalive, "1", :closed}, 500
    end
  end

  describe "close" do
    test "an incomplete helper is signalled and waited for a bounded time" do
      {_session, handle} = connected("")
      assert ExecBridge.close(handle) == :ok

      assert collect() == [:completed?, {:signal, 15}, {:wait, 3_000}, :close]
    end

    test "a completed helper is not signalled" do
      {_session, handle} = connected("", %{}, results: %{completed?: {:ok, true}})
      assert ExecBridge.close(handle) == :ok
      assert collect() == [:completed?, :close]
    end

    test "an operation that cannot be read is not signalled" do
      {_session, handle} =
        connected("", %{}, results: %{completed?: {:error, %Incus.Error{kind: :closed}}})

      assert ExecBridge.close(handle) == :ok
      assert collect() == [:completed?, :close]
    end

    test "close survives a dead session" do
      {session, handle} = connected("")
      GenServer.stop(session)
      assert ExecBridge.close(handle) == :ok
    end
  end

  test "helper stderr is reported to the observer and never to the relay" do
    {_session, handle} =
      connected(Fake.frame("out"), %{observer: self()}, stderr: [{:binary, "warn"}, :closed])

    assert_receive {:helper_stderr, "warn"}, 500
    assert ExecBridge.recv(handle, 1_024, deadline()) == {:ok, "out"}
  end

  defp collect(acc \\ []) do
    receive do
      {:incus, event} -> collect([event | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end

  defp flush_pings do
    receive do
      {:incus, {:ping, _}} -> flush_pings()
    after
      0 -> :ok
    end
  end
end
