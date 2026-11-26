defmodule Opsmaru.Containers.Acceptance.ExecSocketBridgeHalfClose do
  @moduledoc false

  alias Opsmaru.Containers.Transport.ExecBridge
  alias Opsmaru.Containers.Transport.Stream
  alias Opsmaru.Incus.Session

  @peer ~S"""
  use strict;
  use warnings;
  use Socket;

  my ($path, $first) = @ARGV;
  END { unlink($path) if defined $path; }
  $| = 1;
  alarm(12);
  umask(0077);
  socket(my $listener, PF_UNIX, SOCK_STREAM, 0) or die "socket: $!";
  bind($listener, sockaddr_un($path)) or die "bind: $!";
  listen($listener, 1) or die "listen: $!";
  print "ready\n";
  accept(my $peer, $listener) or die "accept: $!";

  if ($first eq "peer") {
    syswrite($peer, "output-before-peer-eof") or die "write: $!";
    shutdown($peer, SHUT_WR) or die "output close: $!";
  }

  my $input = "";
  while (1) {
    my $count = sysread($peer, my $chunk, 256);
    die "read: $!" unless defined $count;
    last unless $count;
    $input .= $chunk;
    die "unexpected input size" if length($input) > 64;
  }
  die "wrong input" unless $input eq "input-for-$first";

  if ($first eq "client") {
    syswrite($peer, "output-after-client-eof") or die "write: $!";
    shutdown($peer, SHUT_WR) or die "output close: $!";
  }

  print "verified-$first\n";
  """

  def run(target, helper) do
    for first <- ["client", "peer"] do
      path = unique_socket()
      peer = start_peer(target, path, first)
      deadline = now() + 10_000
      options = %{helper: helper, socket: path, observer: self()}
      {:ok, stream} = ExecBridge.dial(target, options, deadline)

      try do
        verify_direction(stream, first, deadline)
        {:ok, %{exit_status: 0}} = Task.await(peer)
        {:ok, 0} = await_status(stream.handle.session, deadline)
        IO.puts(Jason.encode!(%{half_close: first, payload_valid: true, helper_exit_status: 0}))
      after
        Stream.close(stream)
      end
    end
  end

  defp start_peer(target, path, first) do
    owner = self()
    ref = make_ref()
    ready = "ready\n"

    sink = fn
      ^ready ->
        send(owner, {:peer_ready, ref})
        :ok

      _ ->
        :ok
    end

    request = %{
      "command" => ["perl", "-e", @peer, path, first],
      "interactive" => false,
      "wait-for-websocket" => true,
      "record-output" => false
    }

    task =
      Task.async(fn ->
        Session.run(target.client, target.instance, request, "", sink, sink,
          timeout: 15_000,
          max_output_bytes: 1_024
        )
      end)

    receive do
      {:peer_ready, ^ref} -> task
    after
      6_000 -> raise "guest fixture did not bind its Unix socket"
    end
  end

  defp verify_direction(stream, "client", deadline) do
    :ok = Stream.send(stream, "input-for-client", deadline)
    :ok = Stream.shutdown_write(stream, deadline)
    "output-after-client-eof" = drain(stream, deadline, [])
  end

  defp verify_direction(stream, "peer", deadline) do
    "output-before-peer-eof" = drain(stream, deadline, [])
    :ok = Stream.send(stream, "input-for-peer", deadline)
    :ok = Stream.shutdown_write(stream, deadline)
  end

  defp drain(stream, deadline, chunks) do
    case Stream.recv(stream, 5, deadline) do
      :eof -> chunks |> Enum.reverse() |> IO.iodata_to_binary()
      {:ok, bytes} -> drain(stream, deadline, [bytes | chunks])
      error -> raise "bridge drain failed: #{inspect(error)}"
    end
  end

  defp await_status(session, deadline) do
    if now() < deadline do
      case Session.exit_status(session) do
        {:error, %Opsmaru.Incus.Error{kind: :operation_pending}} ->
          Process.sleep(30)
          await_status(session, deadline)

        result ->
          result
      end
    else
      {:error, :deadline}
    end
  end

  defp unique_socket do
    suffix = :crypto.strong_rand_bytes(5) |> Base.encode16(case: :lower)
    "/run/occ-bridge-peer-#{suffix}.sock"
  end

  defp now, do: System.monotonic_time(:millisecond)
end
